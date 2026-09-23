use crate::limits::QuotaLimits;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, Timelike, Utc};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

/// Length of a rate-limit block. Claude Code bills usage in 5-hour windows.
const SESSION_HOURS: i64 = 5;
/// Model string Claude Code writes for locally generated messages, which are not billed.
const SYNTHETIC_MODEL: &str = "<synthetic>";
/// Nested usage entries of this kind are separate billed turns, not part of the parent.
const ADVISOR_ITERATION: &str = "advisor_message";
/// Cheap substring test that skips transcript lines with no token usage before parsing JSON.
const USAGE_MARKER: &str = "\"usage\":{";
/// Segments of a model id to keep in the table, so `claude-opus-4-5-20251101` reads `opus-4-5`.
const MODEL_LABEL_SEGMENTS: usize = 3;
/// Length of the `20251101` date stamp that trails most model ids.
const MODEL_DATE_LEN: usize = 8;
/// Leading characters of a session id kept in the table: enough to tell two
/// runs in the same project apart, and to match the transcript file name.
const SESSION_ID_CHARS: usize = 8;
const PROJECTS_DIR: &str = "projects";
/// Comma-separated list of Claude config directories, set by the user.
const CONFIG_DIR_ENV: &str = "CLAUDE_CONFIG_DIR";

#[derive(Clone, Copy, Debug, Default)]
pub struct TokenCounts {
    pub input: u64,
    pub output: u64,
    pub cache_create: u64,
    pub cache_read: u64,
}

impl TokenCounts {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_create + self.cache_read
    }

    fn add(&mut self, other: &Self) {
        self.input += other.input;
        self.output += other.output;
        self.cache_create += other.cache_create;
        self.cache_read += other.cache_read;
    }
}

#[derive(Clone, Debug)]
pub struct UsageRow {
    pub title: String,
    pub detail: String,
    pub tokens: TokenCounts,
    pub active: bool,
}

#[derive(Clone, Debug, Default)]
pub struct UsageReport {
    pub daily: Vec<UsageRow>,
    pub weekly: Vec<UsageRow>,
    pub monthly: Vec<UsageRow>,
    pub sessions: Vec<UsageRow>,
    pub blocks: Vec<UsageRow>,
}

#[derive(Clone)]
struct Entry {
    timestamp: DateTime<Utc>,
    session_id: String,
    project: String,
    model: String,
    tokens: TokenCounts,
    message_id: Option<String>,
    request_id: Option<String>,
    is_sidechain: bool,
}

#[derive(Deserialize)]
struct Line {
    timestamp: Option<String>,
    #[serde(default, rename = "requestId")]
    request_id: Option<String>,
    #[serde(default, rename = "sessionId")]
    session_id: Option<String>,
    #[serde(default, rename = "isSidechain")]
    is_sidechain: Option<bool>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    usage: Option<RawUsage>,
}

#[derive(Deserialize, Clone)]
struct RawUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    iterations: Vec<RawIteration>,
}

#[derive(Deserialize, Clone)]
struct RawIteration {
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
}

#[derive(Default)]
struct Bucket {
    tokens: TokenCounts,
    models: BTreeSet<String>,
    first: Option<DateTime<Utc>>,
    last: Option<DateTime<Utc>>,
}

impl Bucket {
    fn add(&mut self, entry: &Entry) {
        self.tokens.add(&entry.tokens);
        if !entry.model.is_empty() && entry.model != SYNTHETIC_MODEL {
            self.models.insert(short_model(&entry.model));
        }
        self.first = Some(
            self.first
                .map_or(entry.timestamp, |t| t.min(entry.timestamp)),
        );
        self.last = Some(
            self.last
                .map_or(entry.timestamp, |t| t.max(entry.timestamp)),
        );
    }
}

pub fn load_usage() -> UsageSnapshot {
    let limits = crate::limits::fetch_quota_limits();
    if let Err(err) = &limits
        && crate::limits::is_unauthorized(err)
    {
        return UsageSnapshot {
            report: Err(err.clone()),
            limits,
        };
    }
    UsageSnapshot {
        report: load_transcripts(),
        limits,
    }
}

#[derive(Clone, Debug)]
pub struct UsageSnapshot {
    pub report: Result<UsageReport, String>,
    pub limits: Result<QuotaLimits, String>,
}

pub fn load_transcripts() -> Result<UsageReport, String> {
    let files = usage_files();
    if files.is_empty() {
        return Err(
            "No Claude Code logs found in ~/.claude/projects or ~/.config/claude/projects".into(),
        );
    }

    let mut entries = Vec::new();
    for path in &files {
        read_file(path, &mut entries);
    }
    let entries = dedup(entries);
    if entries.is_empty() {
        return Err("Found Claude Code logs, but none had token usage".into());
    }

    Ok(UsageReport {
        daily: aggregate_daily(&entries),
        weekly: aggregate_weekly(&entries),
        monthly: aggregate_monthly(&entries),
        sessions: aggregate_sessions(&entries),
        blocks: aggregate_blocks(&entries),
    })
}

/// Directories that hold a `projects` folder of transcripts. An explicit
/// `CLAUDE_CONFIG_DIR` wins outright; otherwise both default locations count,
/// because a machine can have logs under each.
fn claude_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(raw) = std::env::var(CONFIG_DIR_ENV) {
        for part in raw.split(',') {
            let path = expand_home(part.trim());
            // Accept the config directory or the projects folder inside it.
            let root = if path.file_name().is_some_and(|name| name == PROJECTS_DIR) {
                path.parent().unwrap_or(&path).to_path_buf()
            } else {
                path
            };
            if root.join(PROJECTS_DIR).is_dir() {
                roots.push(root);
            }
        }
        if !roots.is_empty() {
            return roots;
        }
    }

    if let Some(home) = home_dir() {
        let xdg = std::env::var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join(".config"));
        for root in [xdg.join("claude"), home.join(".claude")] {
            if root.join(PROJECTS_DIR).is_dir() {
                roots.push(root);
            }
        }
    }
    roots
}

fn usage_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    for root in claude_roots() {
        walk_jsonl(&root.join(PROJECTS_DIR), &mut files);
    }
    files.sort();
    files
}

fn walk_jsonl(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_jsonl(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
}

fn read_file(path: &Path, out: &mut Vec<Entry>) {
    let Ok(text) = fs::read_to_string(path) else {
        return;
    };
    let session_id = session_id_from_path(path);
    for line in text.lines() {
        // Most lines are prompts and tool output. Skipping them by substring is
        // far cheaper than handing every line to serde.
        if !line.contains(USAGE_MARKER) {
            continue;
        }
        let Ok(parsed) = serde_json::from_str::<Line>(line) else {
            continue;
        };
        let Some(message) = parsed.message else {
            continue;
        };
        let Some(usage) = message.usage else {
            continue;
        };
        let Some(timestamp) = parsed.timestamp.as_deref().and_then(parse_timestamp) else {
            continue;
        };
        let model = message
            .model
            .clone()
            .filter(|model| !model.trim().is_empty())
            .unwrap_or_default();
        let tokens = TokenCounts {
            input: usage.input_tokens,
            output: usage.output_tokens,
            cache_create: usage.cache_creation_input_tokens,
            cache_read: usage.cache_read_input_tokens,
        };
        let session = parsed
            .session_id
            .clone()
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| session_id.clone());
        let project = parsed.cwd.as_deref().map(project_name).unwrap_or_default();
        out.push(Entry {
            timestamp,
            session_id: session.clone(),
            project: project.clone(),
            model,
            tokens,
            message_id: message.id.clone(),
            request_id: parsed.request_id.clone(),
            is_sidechain: parsed.is_sidechain.unwrap_or(false),
        });

        // Advisor turns are billed separately but nest inside the parent's usage
        // block, so they become their own entries. The index keeps their derived
        // message ids distinct, otherwise dedup would collapse them into one.
        for (index, iteration) in usage.iterations.iter().enumerate() {
            if iteration.kind.as_deref() != Some(ADVISOR_ITERATION) {
                continue;
            }
            let advisor_model = iteration.model.clone().unwrap_or_default();
            out.push(Entry {
                timestamp,
                session_id: session.clone(),
                project: project.clone(),
                model: advisor_model,
                tokens: TokenCounts {
                    input: iteration.input_tokens,
                    output: iteration.output_tokens,
                    cache_create: iteration.cache_creation_input_tokens,
                    cache_read: iteration.cache_read_input_tokens,
                },
                message_id: message
                    .id
                    .as_ref()
                    .map(|id| format!("{id}:advisor:{index}")),
                request_id: parsed.request_id.clone(),
                is_sidechain: parsed.is_sidechain.unwrap_or(false),
            });
        }
    }
}

/// Resuming a session copies earlier turns into the new transcript, and a
/// subagent's turns land in both its own file and the parent's, so the same
/// message shows up more than once. Two indexes handle the two cases: an exact
/// (message, request) match is a plain duplicate, while a message seen under a
/// different sidechain flag is the parent-and-subagent pair, where the
/// non-sidechain copy wins.
fn dedup(entries: Vec<Entry>) -> Vec<Entry> {
    let mut exact: HashMap<(String, Option<String>), usize> = HashMap::new();
    let mut by_message: HashMap<String, usize> = HashMap::new();
    let mut kept = Vec::new();

    for entry in entries {
        let Some(message_id) = entry.message_id.clone() else {
            kept.push(entry);
            continue;
        };
        let exact_key = (message_id.clone(), entry.request_id.clone());
        if let Some(&index) = exact.get(&exact_key) {
            if should_replace(&entry, &kept[index]) {
                kept[index] = entry;
            }
            continue;
        }
        if let Some(&index) = by_message.get(&message_id)
            && entry.is_sidechain != kept[index].is_sidechain
        {
            if entry.is_sidechain {
                continue;
            }
            kept[index] = entry;
            exact.insert(exact_key, index);
            continue;
        }
        let index = kept.len();
        exact.insert(exact_key, index);
        by_message.insert(message_id, index);
        kept.push(entry);
    }
    kept
}

/// Between two copies of one message, prefer the non-sidechain one, then the
/// larger token count, since a truncated copy can be written before the turn
/// finishes streaming.
fn should_replace(candidate: &Entry, existing: &Entry) -> bool {
    if candidate.is_sidechain != existing.is_sidechain {
        return existing.is_sidechain;
    }
    candidate.tokens.total() > existing.tokens.total()
}

fn aggregate_daily(entries: &[Entry]) -> Vec<UsageRow> {
    let mut buckets: BTreeMap<String, Bucket> = BTreeMap::new();
    for entry in entries {
        let key = local_date(entry.timestamp);
        buckets.entry(key).or_default().add(entry);
    }
    newest_rows(buckets, |key, bucket| {
        usage_row(format_day_key(&key), models_label(&bucket.models), bucket)
    })
}

fn aggregate_weekly(entries: &[Entry]) -> Vec<UsageRow> {
    let mut buckets: BTreeMap<String, Bucket> = BTreeMap::new();
    for entry in entries {
        let date = entry.timestamp.with_timezone(&Local).date_naive();
        let week = date.iso_week();
        let key = format!("{}-W{:02}", week.year(), week.week());
        buckets.entry(key).or_default().add(entry);
    }
    newest_rows(buckets, |key, bucket| {
        usage_row(format_week_key(&key), models_label(&bucket.models), bucket)
    })
}

fn aggregate_monthly(entries: &[Entry]) -> Vec<UsageRow> {
    let mut buckets: BTreeMap<String, Bucket> = BTreeMap::new();
    for entry in entries {
        let date = entry.timestamp.with_timezone(&Local).date_naive();
        let key = format!("{}-{:02}", date.year(), date.month());
        buckets.entry(key).or_default().add(entry);
    }
    newest_rows(buckets, |key, bucket| {
        usage_row(format_month_key(&key), models_label(&bucket.models), bucket)
    })
}

fn aggregate_sessions(entries: &[Entry]) -> Vec<UsageRow> {
    let mut buckets: BTreeMap<String, Bucket> = BTreeMap::new();
    let mut projects: HashMap<String, String> = HashMap::new();
    for entry in entries {
        buckets
            .entry(entry.session_id.clone())
            .or_default()
            .add(entry);
        if !entry.project.is_empty() {
            projects
                .entry(entry.session_id.clone())
                .or_insert_with(|| entry.project.clone());
        }
    }
    let mut rows: Vec<(u64, UsageRow)> = buckets
        .into_iter()
        .map(|(session_id, bucket)| {
            let last = bucket
                .last
                .map(format_session_date)
                .unwrap_or_else(|| "unknown".into());
            (
                bucket.tokens.total(),
                usage_row(
                    session_title(projects.get(&session_id), &session_id),
                    last,
                    bucket,
                ),
            )
        })
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    rows.into_iter().map(|(_, row)| row).collect()
}

/// Rebuilds the 5-hour windows the way Claude Code opens them: the first turn
/// starts a block on the hour, and a turn closes the block if it lands more than
/// five hours after the block started or after the previous turn.
fn aggregate_blocks(entries: &[Entry]) -> Vec<UsageRow> {
    let duration = Duration::hours(SESSION_HOURS);
    let mut sorted = entries.to_vec();
    sorted.sort_by_key(|entry| entry.timestamp);

    let now = Utc::now();
    let mut rows = Vec::new();
    let mut start: Option<DateTime<Utc>> = None;
    let mut current: Vec<Entry> = Vec::new();

    for entry in sorted {
        match start {
            None => {
                start = Some(floor_to_hour(entry.timestamp));
                current = vec![entry];
            }
            Some(block_start) => {
                let last = current
                    .last()
                    .map(|item| item.timestamp)
                    .unwrap_or(block_start);
                let since_start = entry.timestamp - block_start;
                let since_last = entry.timestamp - last;
                if since_start > duration || since_last > duration {
                    rows.push(block_row(block_start, &current, now, duration));
                    start = Some(floor_to_hour(entry.timestamp));
                    current = vec![entry];
                } else {
                    current.push(entry);
                }
            }
        }
    }

    if let Some(block_start) = start {
        rows.push(block_row(block_start, &current, now, duration));
    }
    rows.reverse();
    rows
}

fn block_row(
    start: DateTime<Utc>,
    entries: &[Entry],
    now: DateTime<Utc>,
    duration: Duration,
) -> UsageRow {
    let end = start + duration;
    let actual_end = entries.last().map(|entry| entry.timestamp).unwrap_or(start);
    let active = now - actual_end < duration && now < end;
    let mut bucket = Bucket::default();
    for entry in entries {
        bucket.add(entry);
    }

    let status = if active {
        let remaining = (end - now).max(Duration::zero());
        format!("{} left", format_duration(remaining))
    } else {
        format!("Completed · {}", format_duration(actual_end - start))
    };

    UsageRow {
        title: start
            .with_timezone(&Local)
            .format("%b %d %H:%M")
            .to_string(),
        detail: status,
        tokens: bucket.tokens,
        active,
    }
}

fn floor_to_hour(timestamp: DateTime<Utc>) -> DateTime<Utc> {
    timestamp
        .with_minute(0)
        .and_then(|t| t.with_second(0))
        .and_then(|t| t.with_nanosecond(0))
        .unwrap_or(timestamp)
}

/// Newest bucket first. Every key here is a zero-padded date, week, or month, so
/// the map's lexical order is also chronological order and reversing is enough.
fn newest_rows(
    buckets: BTreeMap<String, Bucket>,
    mut to_row: impl FnMut(String, Bucket) -> UsageRow,
) -> Vec<UsageRow> {
    let mut rows: Vec<UsageRow> = buckets
        .into_iter()
        .map(|(key, bucket)| to_row(key, bucket))
        .collect();
    rows.reverse();
    rows
}

/// Transcripts live at `projects/<project>/<session>.jsonl`, and a subagent's
/// turns at `projects/<project>/<session>/subagents/<agent>.jsonl`. Subagent
/// files report the parent session so their tokens roll up into it. Only used
/// when a line has no `sessionId` of its own.
fn session_id_from_path(path: &Path) -> String {
    let parts: Vec<_> = path.iter().filter_map(|part| part.to_str()).collect();
    let Some(projects) = parts.iter().position(|part| *part == "projects") else {
        return path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("unknown")
            .to_string();
    };
    let relative = &parts[projects + 1..];
    if relative.len() >= 4 && relative[relative.len() - 2] == "subagents" {
        return relative[relative.len() - 3].to_string();
    }
    if relative.len() == 2 {
        return relative[1]
            .strip_suffix(".jsonl")
            .unwrap_or(relative[1])
            .to_string();
    }
    let name = relative
        .get(relative.len().saturating_sub(2))
        .copied()
        .unwrap_or("unknown");
    name.strip_suffix(".jsonl").unwrap_or(name).to_string()
}

fn parse_timestamp(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn local_date(timestamp: DateTime<Utc>) -> String {
    timestamp
        .with_timezone(&Local)
        .format("%Y-%m-%d")
        .to_string()
}

fn usage_row(title: String, detail: String, bucket: Bucket) -> UsageRow {
    UsageRow {
        title,
        detail,
        tokens: bucket.tokens,
        active: false,
    }
}

/// Always with the year. Unlike the day, week, and month tabs, this list is
/// ordered by token count, so nothing around a date says which year it fell in.
fn format_session_date(timestamp: DateTime<Utc>) -> String {
    timestamp
        .with_timezone(&Local)
        .format("%b %d, %Y")
        .to_string()
}

fn format_day_key(key: &str) -> String {
    let Ok(date) = NaiveDate::parse_from_str(key, "%Y-%m-%d") else {
        return key.to_string();
    };
    if date.year() == Local::now().year() {
        date.format("%b %d").to_string()
    } else {
        date.format("%b %d, %Y").to_string()
    }
}

fn format_week_key(key: &str) -> String {
    if let Some((year, week)) = key.split_once("-W") {
        format!("W{week} {year}")
    } else {
        key.to_string()
    }
}

fn format_month_key(key: &str) -> String {
    let mut parts = key.split('-');
    let (Some(year), Some(month)) = (parts.next(), parts.next()) else {
        return key.to_string();
    };
    let Ok(year) = year.parse::<i32>() else {
        return key.to_string();
    };
    let Ok(month) = month.parse::<u32>() else {
        return key.to_string();
    };
    NaiveDate::from_ymd_opt(year, month, 1)
        .map(|date| date.format("%b %Y").to_string())
        .unwrap_or_else(|| key.to_string())
}

fn short_model(model: &str) -> String {
    model
        .trim_start_matches("claude-")
        .split('-')
        .filter(|part| !is_date_suffix(part))
        .take(MODEL_LABEL_SEGMENTS)
        .collect::<Vec<_>>()
        .join("-")
}

fn is_date_suffix(part: &str) -> bool {
    part.len() == MODEL_DATE_LEN && part.chars().all(|ch| ch.is_ascii_digit())
}

/// Sessions carry no name of their own, so the folder Claude Code was launched
/// in stands in for one. Transcripts record it on every line as `cwd`.
fn project_name(cwd: &str) -> String {
    Path::new(cwd)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or(cwd)
        .to_string()
}

/// The project reads as the session's name; the id trailing it keeps two
/// sessions in the same project apart. Sessions predating the `cwd` field, or
/// rolled up from a path, have only the id.
fn session_title(project: Option<&String>, session_id: &str) -> String {
    let short = short_session(session_id);
    match project {
        Some(project) => format!("{project} · {short}"),
        None => short,
    }
}

fn short_session(session_id: &str) -> String {
    session_id
        .split('-')
        .next()
        .unwrap_or(session_id)
        .chars()
        .take(SESSION_ID_CHARS)
        .collect()
}

fn models_label(models: &BTreeSet<String>) -> String {
    if models.is_empty() {
        "unknown model".into()
    } else {
        models.iter().cloned().collect::<Vec<_>>().join(", ")
    }
}

pub fn format_tokens(value: u64) -> String {
    if value >= 1_000_000 {
        compact_count(value as f64 / 1_000_000.0, "M")
    } else if value >= 1_000 {
        compact_count(value as f64 / 1_000.0, "K")
    } else {
        value.to_string()
    }
}

fn compact_count(value: f64, unit: &str) -> String {
    if (value - value.round()).abs() < 0.05 {
        format!("{:.0}{unit}", value.round())
    } else {
        format!("{value:.1}{unit}")
    }
}

fn format_duration(duration: Duration) -> String {
    let total_minutes = duration.num_minutes().max(0);
    let hours = total_minutes / 60;
    let minutes = total_minutes % 60;
    if hours > 0 {
        format!("{hours}h {minutes}m")
    } else {
        format!("{minutes}m")
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn expand_home(raw: &str) -> PathBuf {
    if let Some(rest) = raw.strip_prefix("~/")
        && let Some(home) = home_dir()
    {
        return home.join(rest);
    }
    PathBuf::from(raw)
}
