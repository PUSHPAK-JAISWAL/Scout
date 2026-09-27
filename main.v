module main

import veb
import db.sqlite
import net.http
import net.urllib as _
import json2
import os
import time
import appwin

const groq_model = 'openai/gpt-oss-20b'

pub struct Context {
	veb.Context
}

pub struct App {
pub mut:
	db sqlite.DB
}

// ---------- JSON shapes ----------
struct Issue {
	id         int
	repo       string
	title      string
	url        string
	labels     string
	score      int
	difficulty string
	reason     string
	plan       string
	status     string
	draft      string
}

struct State {
	has_pat  bool
	has_groq bool
	skills   string
	learn    string
	issues   []Issue
}

struct GhLabel {
	name string
}

struct GhIssue {
	title          string
	body           string
	html_url       string
	repository_url string
	comments       int
	labels         []GhLabel
}

struct GhSearch {
	items []GhIssue
}

struct GqlReq {
	query     string
	variables map[string]string
}

struct GqlCount {
	total int
}

struct GqlRepo {
	full string
}

struct GqlLabels {
	nodes []GhLabel
}

struct GqlIssue {
	title      string
	url        string
	body       string
	n          GqlCount
	labels     GqlLabels
	repository GqlRepo
}

struct GqlSearch {
	nodes []GqlIssue
}

struct GqlData {
	a0 GqlSearch
	a1 GqlSearch
	a2 GqlSearch
	a3 GqlSearch
	a4 GqlSearch
	a5 GqlSearch
	a6 GqlSearch
	a7 GqlSearch
}

struct GqlResp {
	data GqlData
}

struct GhRepo {
	language string
	fork     bool
}

struct ChatMsg {
	role    string
	content string
}

struct ChatReq {
	model           string
	messages        []ChatMsg
	temperature     f64
	response_format map[string]string
}

struct ChatChoice {
	message ChatMsg
}

struct ChatResp {
	choices []ChatChoice
}

struct Eval {
	score      int
	level      string
	reason     string
	plan       string
}

struct Draft {
	comment string
}

struct SettingsReq {
	pat    string
	groq   string
	skills string
	learn  string
}

struct ScanReq {
	level string
}

struct IdReq {
	id     int
	status string
}

// ---------- helpers ----------
fn fail(mut ctx Context, msg string) veb.Result {
	mut m := map[string]string{}
	m['error'] = msg
	return ctx.send_response_to_client('application/json', json2.encode(m))
}

fn ok(mut ctx Context, body string) veb.Result {
	return ctx.send_response_to_client('application/json', body)
}

fn (mut app App) get(k string) string {
	rows := app.db.exec_param('SELECT v FROM settings WHERE k=?', k) or { return '' }
	if rows.len == 0 {
		return ''
	}
	return rows[0].vals[0]
}

fn (mut app App) put(k string, v string) {
	app.db.exec_param_many('INSERT INTO settings(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v',
		[k, v]) or {}
}

fn gh_get(pat string, url string) !string {
	mut req := http.new_request(.get, url, '')
	req.add_custom_header('Authorization', 'Bearer ${pat}')!
	req.add_custom_header('Accept', 'application/vnd.github+json')!
	req.add_custom_header('User-Agent', 'open-source-scout-v')!
	resp := req.do()!
	if resp.status_code != 200 {
		return error('GitHub ${resp.status_code}: ${resp.body}')
	}
	return resp.body.replace('"body":null', '"body":""').replace('"language":null', '"language":""')
}

// One GraphQL request carries several searches at once (aliased a0, a1, ...),
// so GitHub sees a handful of calls instead of a burst of REST searches that
// trips the secondary limit. Kept small (<=4 per request): a wider request
// asks more of GitHub's servers per call and is more likely to time out with
// a 502, which is a server-side gateway error, not a rate limit.
fn gh_search_once(pat string, qs []string) !GqlData {
	d := '$'
	mut defs := []string{}
	mut fields := []string{}
	mut vars := map[string]string{}
	for i, q in qs {
		defs << '${d}q${i}: String!'
		fields << 'a${i}: search(query: ${d}q${i}, type: ISSUE, first: 8) { nodes { ...F } }'
		vars['q${i}'] = q
	}
	query := 'query(' + defs.join(', ') + ') { ' + fields.join(' ') +
		' } fragment F on Issue { title url body n: comments { total: totalCount } labels(first: 5) { nodes { name } } repository { full: nameWithOwner } }'
	mut last_err := ''
	for attempt in 0 .. 3 {
		if attempt > 0 {
			time.sleep(time.Duration(attempt) * 1200 * time.millisecond)
		}
		mut req := http.new_request(.post, 'https://api.github.com/graphql', json2.encode(GqlReq{
			query:     query
			variables: vars
		}))
		req.add_custom_header('Authorization', 'Bearer ${pat}')!
		req.add_custom_header('Content-Type', 'application/json')!
		req.add_custom_header('User-Agent', 'open-source-scout-v')!
		resp := req.do() or {
			last_err = err.msg()
			continue
		}
		if resp.status_code == 403 || resp.status_code == 429 {
			return error('GitHub is rate limiting this token. Wait a few minutes, then try again.')
		}
		if resp.status_code in [502, 503, 504] {
			// Transient gateway hiccup on GitHub's side, not our request. Retry.
			last_err = 'GitHub ${resp.status_code} (temporary)'
			continue
		}
		if resp.status_code != 200 {
			return error('GitHub ${resp.status_code}: ${clip(resp.body, 300)}')
		}
		if resp.body.to_lower().contains('rate limit') && !resp.body.contains('"nodes"') {
			return error('GitHub is rate limiting this token. Wait a few minutes, then try again.')
		}
		r := json2.decode[GqlResp](resp.body) or {
			return error('Could not read the GitHub answer: ${clip(resp.body, 300)}')
		}
		return r.data
	}
	return error('GitHub is temporarily unavailable (${last_err}). Try Find issues again in a moment.')
}

// Runs all the searches, four at a time, so each single GraphQL request stays
// light. Chunks that error are skipped rather than failing the whole scan, so
// one flaky batch doesn't waste the ones that already succeeded.
fn gh_search(pat string, qs []string) ![]GhIssue {
	mut out := []GhIssue{}
	mut urls := map[string]bool{}
	mut ok_count := 0
	mut last_err := ''
	for i := 0; i < qs.len; i += 4 {
		chunk := qs[i..if i + 4 < qs.len { i + 4 } else { qs.len }]
		gd := gh_search_once(pat, chunk) or {
			last_err = err.msg()
			continue
		}
		ok_count++
		for grp in [gd.a0, gd.a1, gd.a2, gd.a3, gd.a4, gd.a5, gd.a6, gd.a7] {
			for node in grp.nodes {
				if node.url == '' || node.url in urls {
					continue
				}
				urls[node.url] = true
				out << GhIssue{
					title:          node.title
					body:           node.body
					html_url:       node.url
					repository_url: 'https://api.github.com/repos/' + node.repository.full
					comments:       node.n.total
					labels:         node.labels.nodes
				}
			}
		}
		if i + 4 < qs.len {
			time.sleep(400 * time.millisecond)
		}
	}
	if ok_count == 0 {
		return error(last_err)
	}
	return out
}

fn groq(key string, system string, user string) !string {
	body := json2.encode(ChatReq{
		model:           groq_model
		messages:        [ChatMsg{
			role:    'system'
			content: system
		}, ChatMsg{
			role:    'user'
			content: user
		}]
		temperature:     0.2
		response_format: {
			'type': 'json_object'
		}
	})
	mut req := http.new_request(.post, 'https://api.groq.com/openai/v1/chat/completions',
		body)
	req.add_custom_header('Authorization', 'Bearer ${key}')!
	req.add_custom_header('Content-Type', 'application/json')!
	resp := req.do()!
	if resp.status_code != 200 {
		return error('Groq ${resp.status_code}: ${resp.body}')
	}
	r := json2.decode[ChatResp](resp.body)!
	if r.choices.len == 0 {
		return error('Groq returned no answer')
	}
	return r.choices[0].message.content
}

fn clip(s string, n int) string {
	if s.len > n {
		return s[..n]
	}
	return s
}

// ---------- routes ----------
pub fn (mut app App) index(mut ctx Context) veb.Result {
	page := $embed_file('static/index.html')
	return ctx.html(page.to_string())
}

@['/api/state'; get]
pub fn (mut app App) state(mut ctx Context) veb.Result {
	rows := app.db.exec("SELECT id,repo,title,url,labels,score,difficulty,reason,plan,status,draft FROM issues WHERE status!='dismissed' ORDER BY score DESC, id DESC") or {
		[]sqlite.Row{}
	}
	mut issues := []Issue{}
	for r in rows {
		issues << Issue{
			id:         r.vals[0].int()
			repo:       r.vals[1]
			title:      r.vals[2]
			url:        r.vals[3]
			labels:     r.vals[4]
			score:      r.vals[5].int()
			difficulty: r.vals[6]
			reason:     r.vals[7]
			plan:       r.vals[8]
			status:     r.vals[9]
			draft:      r.vals[10]
		}
	}
	return ok(mut ctx, json2.encode(State{
		has_pat:  app.get('pat') != ''
		has_groq: app.get('groq') != ''
		skills:   app.get('skills')
		learn:    app.get('learn')
		issues:   issues
	}))
}

@['/api/settings'; post]
pub fn (mut app App) settings(mut ctx Context) veb.Result {
	s := json2.decode[SettingsReq](ctx.req.data) or { return fail(mut ctx, 'Bad request') }
	if s.pat != '' {
		app.put('pat', s.pat.trim_space())
	}
	if s.groq != '' {
		app.put('groq', s.groq.trim_space())
	}
	app.put('skills', s.skills.trim_space())
	app.put('learn', s.learn.trim_space())
	return ok(mut ctx, '{"ok":true}')
}

// Learn skills from the languages in the user's own repos.
@['/api/skills/detect'; post]
pub fn (mut app App) detect(mut ctx Context) veb.Result {
	pat := app.get('pat')
	if pat == '' {
		return fail(mut ctx, 'Save your GitHub token first.')
	}
	body := gh_get(pat, 'https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner') or {
		return fail(mut ctx, err.msg())
	}
	repos := json2.decode[[]GhRepo](body) or { return fail(mut ctx, 'Could not read your repos.') }
	mut counts := map[string]int{}
	for r in repos {
		if r.language != '' && !r.fork {
			counts[r.language]++
		}
	}
	mut keys := counts.keys()
	for i in 0 .. keys.len {
		for j in i + 1 .. keys.len {
			if counts[keys[j]] > counts[keys[i]] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	if keys.len == 0 {
		return fail(mut ctx, 'No languages found. Type your skills by hand.')
	}
	top := keys[..if keys.len > 6 { 6 } else { keys.len }].join(', ')
	app.put('skills', top)
	mut m := map[string]string{}
	m['skills'] = top
	return ok(mut ctx, json2.encode(m))
}

fn split_list(s string) []string {
	return s.split(',').map(it.trim_space()).filter(it != '')
}

fn level_frags(level string) []string {
	mut f := match level {
		'trivial' { ['typo in:title', 'label:documentation'] }
		'easy' { ['label:"good first issue"'] }
		'medium' { ['label:"help wanted"'] }
		'hard' { ['label:"help wanted" comments:>3', 'label:bug'] }
		else { ['label:"good first issue"', 'label:"help wanted"', 'typo in:title'] } // 'any': a mix, not just good-first-issue
	}
	// A great many maintainers never label issues at all, so a label-only
	// search walks right past good ones. Always also look at unlabeled
	// issues; Groq judges each issue's real difficulty from its text, not
	// from whatever label (or lack of one) it happens to carry.
	f << 'no:label'
	f << 'no:label comments:<3'
	return f
}

// Find issues for the chosen level, then let Groq grade each one against
// what you know and what you want to learn.
@['/api/scan'; post]
pub fn (mut app App) scan(mut ctx Context) veb.Result {
	sr := json2.decode[ScanReq](ctx.req.data) or { ScanReq{
		level: 'any'
	} }
	pat := app.get('pat')
	key := app.get('groq')
	know := app.get('skills')
	learn := app.get('learn')
	if pat == '' || key == '' {
		return fail(mut ctx, 'Add your GitHub token and Groq key first.')
	}
	mut langs := split_list(know)
	if langs.len > 3 {
		langs = langs[..3].clone()
	}
	ls := split_list(learn)
	if ls.len > 0 {
		langs << ls[0]
	}
	if langs.len == 0 {
		return fail(mut ctx, 'Add at least one skill you know or want to learn.')
	}
	frags := level_frags(sr.level)
	// Spread the 8-query budget across frags first, languages second, so
	// "Any" samples every difficulty instead of filling up on the first one.
	mut qs := []string{}
	mut li := 0
	for qs.len < 8 && qs.len < frags.len * langs.len {
		frag := frags[qs.len % frags.len]
		s := langs[li % langs.len]
		qs << 'is:issue is:open no:assignee -linked:pr archived:false ${frag} language:${s}'
		li++
	}
	cands := gh_search(pat, qs) or { return fail(mut ctx, err.msg()) }
	mut matched := 0
	mut checked := 0
	mut problem := ''
	for c in cands {
		if checked >= 12 {
			break
		}
		seen := app.db.exec_param('SELECT 1 FROM issues WHERE url=?', c.html_url) or {
			[]sqlite.Row{}
		}
		if seen.len > 0 {
			continue
		}
		repo := c.repository_url.replace('https://api.github.com/repos/', '')
		labels := c.labels.map(it.name).join(', ')
		sys := 'You grade a GitHub issue for one contributor. Reply only with JSON: {"score":0-100,"level":"trivial|easy|medium|hard","reason":"one or two sentences on fit","plan":"three short steps to start"}. Judge the level from the issue title and body yourself; do not just copy a GitHub label, since many issues have no label or a misleading one. Levels: trivial = typo, wording, rename a variable, change a constant or config value, one-line edit; easy = small self-contained change in one file; medium = several files or needs some project knowledge; hard = design work or deep knowledge. Score by fit: high when it uses skills the contributor knows, a little lower for skills they want to learn (say it is a good stretch), low when it needs skills in neither list or is vague, stale, or likely taken.'
		usr := 'Knows: ${know}\nWants to learn: ${learn}\nRepo: ${repo}\nTitle: ${c.title}\nLabels: ${labels}\nComments: ${c.comments}\nBody:\n${clip(c.body, 1800)}'
		if checked > 0 {
			time.sleep(1500 * time.millisecond) // stay under Groq's per-minute limit
		}
		out := groq(key, sys, usr) or {
			problem = err.msg()
			break
		}
		checked++
		ev := json2.decode[Eval](out) or { continue }
		lv := if ev.level in ['trivial', 'easy', 'medium', 'hard'] { ev.level } else { 'medium' }
		app.db.exec_param_many('INSERT OR IGNORE INTO issues(url,repo,title,body,labels,score,difficulty,reason,plan,status,draft) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
			[c.html_url, repo, c.title, clip(c.body, 1800), labels, ev.score.str(), lv, ev.reason,
			ev.plan, 'new', '']) or { continue }
		if sr.level == 'any' || sr.level == lv {
			matched++
		}
	}
	if problem != '' && checked == 0 {
		return fail(mut ctx, problem)
	}
	return ok(mut ctx, '{"added":${matched},"checked":${checked}}')
}

@['/api/draft'; post]
pub fn (mut app App) draft(mut ctx Context) veb.Result {
	r := json2.decode[IdReq](ctx.req.data) or { return fail(mut ctx, 'Bad request') }
	key := app.get('groq')
	rows := app.db.exec_param('SELECT repo,title,body,plan FROM issues WHERE id=?', r.id.str()) or {
		[]sqlite.Row{}
	}
	if rows.len == 0 {
		return fail(mut ctx, 'Issue not found.')
	}
	v := rows[0].vals
	sys := 'You write a short, polite GitHub comment asking a maintainer to be assigned an issue. Mention one concrete thing about the issue and how you would approach it. No filler. Reply only with JSON: {"comment":"..."}'
	usr := 'I know: ${app.get('skills')}. I want to learn: ${app.get('learn')}.\nRepo: ${v[0]}\nIssue: ${v[1]}\n${v[2]}\nMy plan: ${v[3]}'
	out := groq(key, sys, usr) or { return fail(mut ctx, err.msg()) }
	d := json2.decode[Draft](out) or { return fail(mut ctx, 'Groq gave an unreadable draft. Try again.') }
	app.db.exec_param_many('UPDATE issues SET draft=? WHERE id=?', [d.comment, r.id.str()]) or {}
	return ok(mut ctx, json2.encode(d))
}

@['/api/status'; post]
pub fn (mut app App) status(mut ctx Context) veb.Result {
	r := json2.decode[IdReq](ctx.req.data) or { return fail(mut ctx, 'Bad request') }
	app.db.exec_param_many('UPDATE issues SET status=? WHERE id=?', [r.status, r.id.str()]) or {}
	return ok(mut ctx, '{"ok":true}')
}

fn main() {
	mut app := &App{
		db: sqlite.connect(os.join_path(appwin.portable_dir('Scout'), 'scout.db')) or { panic(err) }
	}
	app.db.exec_none('CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT)')
	app.db.exec_none('CREATE TABLE IF NOT EXISTS issues(id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT UNIQUE, repo TEXT, title TEXT, body TEXT, labels TEXT, score INTEGER, difficulty TEXT, reason TEXT, plan TEXT, status TEXT, draft TEXT, created TEXT DEFAULT CURRENT_TIMESTAMP)')
	// veb.run_at blocks, so the server runs on its own thread; the main
	// thread is reserved for the native window, which every OS webview
	// engine requires.
	spawn fn (mut app App) {
		veb.run_at[App, Context](mut app, host: '127.0.0.1', port: 8787, family: .ip) or { panic(err) }
	}(mut app)
	appwin.run(title: 'Scout', url: 'http://127.0.0.1:8787', port: 8787)
	exit(0) // the window closed; nothing left for this process to do
}