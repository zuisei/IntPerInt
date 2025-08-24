#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sstream>
#include <map>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <filesystem>
#include <chrono>
#include <fstream>
#include <csignal>
#include <sys/wait.h>

namespace fs = std::filesystem;

static const char* SOCK_PATH = "/tmp/intperint.sock";

struct JobInfo {
    std::string id;
    std::string type; // image|video|llm
    std::string outPath;
    std::string dir;
    std::atomic<int> progress{0};
    std::atomic<bool> running{false};
    std::atomic<bool> done{false};
    std::atomic<bool> error{false};
    int exitCode = 0;
};

static std::mutex g_jobs_mtx;
static std::map<std::string, JobInfo> g_jobs;
// chat job pid 管理（cancel用）
static std::mutex g_chat_mtx;
static std::map<std::string, pid_t> g_chat_pids; // jobid -> child pid

static std::string now_id() {
    using namespace std::chrono;
    auto t = system_clock::now();
    auto tt = system_clock::to_time_t(t);
    std::tm tm{};
    localtime_r(&tt, &tm);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%04d%02d%02d-%02d%02d%02d",
                  tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                  tm.tm_hour, tm.tm_min, tm.tm_sec);
    // pid suffix for uniqueness
    std::ostringstream oss; oss << buf << "-" << getpid() << "-" << std::this_thread::get_id();
    return oss.str();
}

static std::string home_outputs_base() {
    const char* home = std::getenv("HOME");
    if (!home) home = ".";
    fs::path p = fs::path(home)/"Library"/"Application Support"/"IntPerInt"/"outputs";
    fs::create_directories(p);
    return p.string();
}

static std::string escape_quotes(const std::string& s) {
    std::string out; out.reserve(s.size()+8);
    for (char c: s) { if (c=='"') out += '\\'; out += c; }
    return out;
}

static std::string read_file(const fs::path& p) {
    std::ifstream ifs(p, std::ios::in | std::ios::binary);
    if (!ifs) return {};
    std::ostringstream ss; ss << ifs.rdbuf();
    return ss.str();
}

static void write_file(const fs::path& p, const std::string& s) {
    fs::create_directories(p.parent_path());
    std::ofstream ofs(p, std::ios::out | std::ios::binary | std::ios::trunc);
    ofs << s;
}

static std::string json_get_string(const std::string& json, const std::string& key) {
    // super-naive extractor for "key":"value" (no escaped quotes inside value)
    std::string patt = "\"" + key + "\"";
    auto pos = json.find(patt);
    if (pos == std::string::npos) return {};
    pos = json.find(':', pos);
    if (pos == std::string::npos) return {};
    pos = json.find('"', pos);
    if (pos == std::string::npos) return {};
    auto end = json.find('"', pos+1);
    if (end == std::string::npos) return {};
    return json.substr(pos+1, end-(pos+1));
}

static std::string json_get_string_from_pos(const std::string& json, size_t startPos, const std::string& key) {
    std::string patt = "\"" + key + "\"";
    auto pos = json.find(patt, startPos);
    if (pos == std::string::npos) return {};
    pos = json.find(':', pos);
    if (pos == std::string::npos) return {};
    pos = json.find('"', pos);
    if (pos == std::string::npos) return {};
    auto end = json.find('"', pos+1);
    if (end == std::string::npos) return {};
    return json.substr(pos+1, end-(pos+1));
}

static int json_get_int(const std::string& json, const std::string& key, int defv) {
    std::string patt = "\"" + key + "\"";
    auto pos = json.find(patt);
    if (pos == std::string::npos) return defv;
    pos = json.find(':', pos);
    if (pos == std::string::npos) return defv;
    // skip spaces
    while (pos < json.size() && (json[pos] == ':' || json[pos]==' ')) pos++;
    // read number
    int sign = 1; if (json[pos]=='-') { sign=-1; pos++; }
    long val=0; while (pos<json.size() && isdigit((unsigned char)json[pos])) { val = val*10 + (json[pos]-'0'); pos++; }
    return (int)(val*sign);
}

static std::string replace_all(std::string s, const std::string& a, const std::string& b) {
    size_t pos=0; while ((pos = s.find(a, pos)) != std::string::npos) { s.replace(pos, a.size(), b); pos += b.size(); }
    return s;
}

static std::string load_config_or_default() {
    fs::path cwd = fs::current_path();
    // 1) CWD/config.json
    fs::path cfg = cwd/"config.json";
    if (fs::exists(cfg)) return read_file(cfg);
    // 2) If running from build/, also try parent/config.json
    if (cwd.filename() == "build") {
        fs::path parent = cwd.parent_path();
        fs::path cfg2 = parent/"config.json";
        if (fs::exists(cfg2)) return read_file(cfg2);
    } else {
        // generic parent fallback
        fs::path cfg2 = cwd.parent_path()/"config.json";
        if (fs::exists(cfg2)) return read_file(cfg2);
    }
    // default minimal config
    return std::string("{\n")+
        "  \"workdir_base\": \""+escape_quotes(home_outputs_base())+"\",\n"+
        "  \"command_templates\": {\n"+
        "    \"SD_CMD_TEMPLATE\": \"/usr/bin/env bash -lc 'echo Generating SD to {OUT_PNG}; sleep 1; > {OUT_PNG}'\",\n"+
        "    \"VIDEO_CMD_TEMPLATE\": \"/usr/bin/env bash -lc 'echo Making video to {OUT_MP4}; sleep 1; > {OUT_MP4}'\",\n"+
        "    \"LLM_CMD_TEMPLATE\": \"/usr/bin/env bash -lc 'echo LLM out to {OUT_TXT}; echo Hello > {OUT_TXT}'\"\n"+
        "  }\n"+
        "}\n";
}

static std::string cfg_get(const std::string& cfg, const std::string& key, const std::string& defv) {
    auto v = json_get_string(cfg, key);
    return v.empty() ? defv : v;
}

// cmd_templates セクション内のキーを探す簡易取得
static std::string cfg_get_in_cmd_templates(const std::string& cfg, const std::string& key) {
    std::string sec = "\"cmd_templates\"";
    auto pos = cfg.find(sec);
    if (pos == std::string::npos) return {};
    // 探した位置から最初の '{' を見つけ、その対応する '}' までを取り出す
    auto br = cfg.find('{', pos);
    if (br == std::string::npos) return {};
    int depth = 0; size_t i = br; size_t end = std::string::npos;
    for (; i < cfg.size(); ++i) {
        if (cfg[i] == '{') depth++;
        else if (cfg[i] == '}') { depth--; if (depth == 0) { end = i; break; } }
    }
    if (end == std::string::npos) return {};
    std::string inner = cfg.substr(br, end - br + 1);
    // inner に対して json_get_string を用い、該当 key を引く
    return json_get_string(inner, key);
}

static std::string cfg_get_cmd_template_any(const std::string& cfg, const std::vector<std::string>& keys) {
    for (auto &k: keys) {
        auto v = cfg_get(cfg, k, "");
        if (!v.empty()) return v;
        v = cfg_get_in_cmd_templates(cfg, k);
        if (!v.empty()) return v;
    }
    return {};
}

static std::string cfg_get_model_field(const std::string& cfg, const std::string& modelKey, const std::string& field) {
    // 非厳密: "<modelKey>" の出現箇所から field を探す
    auto pos = cfg.find("\"" + modelKey + "\"" );
    if (pos == std::string::npos) return {};
    return json_get_string_from_pos(cfg, pos, field);
}

static std::string outputs_base_from_cfg(const std::string& cfg) {
    // prefer workdir_base, fallback to paths.work_base (older), else HOME base
    std::string base = cfg_get(cfg, "workdir_base", "");
    if (base.empty()) base = cfg_get(cfg, "work_base", "");
    if (base.empty()) return home_outputs_base();
    fs::path p = fs::path(base);
    fs::create_directories(p);
    return p.string();
}

static std::string build_cmd(const std::string& tmpl, const std::map<std::string,std::string>& kv) {
    std::string cmd = tmpl;
    for (auto& [k,v] : kv) {
        cmd = replace_all(cmd, "{"+k+"}", v);
    }
    return cmd;
}

static int run_system_logged(const std::string& cmd, const fs::path& logFile) {
    // redirect stdout+stderr to log
    std::string full = cmd + " >> '" + logFile.string() + "' 2>&1";
    int rc = std::system(full.c_str());
    if (rc == -1) return -1; // failed to spawn
    if (WIFEXITED(rc)) return WEXITSTATUS(rc);
    if (WIFSIGNALED(rc)) return 128 + WTERMSIG(rc);
    return rc;
}

// --- LLM streaming: fork/exec + pipe で stdout を逐次 JSON Lines 送信 ---
static void handle_start_chat(const std::string& req, int client_fd, const std::string& cfg) {
    std::string model = json_get_string(req, "model");
    std::string prompt = json_get_string(req, "prompt");
    int tokens = json_get_int(req, "tokens", 256);
    int threads = json_get_int(req, "threads", 8);
    std::string jobid = json_get_string(req, "jobid");
    if (jobid.empty()) jobid = now_id();
    std::string llama_bin = json_get_string(req, "llama_bin");
    std::string model_path = json_get_string(req, "model_path");

    fs::path jobdir = fs::path(outputs_base_from_cfg(cfg))/jobid;
    fs::create_directories(jobdir);
    fs::path log = jobdir/"log.txt";
    write_file(jobdir/"meta.json", std::string("{\n  \"engine\": \"llm\", \"model\": \"") + escape_quotes(model) + "\"\n}\n");

    // コマンドテンプレート取得（上位互換: LLM_CMD_TEMPLATE / llama_run / llm_run）
    std::string tmpl = cfg_get_cmd_template_any(cfg, {"LLM_CMD_TEMPLATE", "llama_run", "llm_run"});
    if (tmpl.empty()) {
        // フォールバック: シンプルにトークンをストリームする疑似コマンド
        tmpl = "/usr/bin/env bash -lc 'for t in Streaming LLM tokens from helper; do echo $t; sleep 0.05; done'";
    }

    // プレースホルダ KV
    std::map<std::string,std::string> kv = {
        {"PROMPT", escape_quotes(prompt)},
        {"TOKENS", std::to_string(tokens)},
        {"THREADS", std::to_string(threads)},
        {"MODEL_PATH", model_path},
        {"LLAMA_BIN", llama_bin},
        {"OUT_TXT", (jobdir/"out.txt").string()}
    };
    // 既定: cfg 側の LLAMA_BIN / MODEL_PATH があれば補完
    if (kv["LLAMA_BIN"].empty()) {
        kv["LLAMA_BIN"] = cfg_get(cfg, "LLAMA_BIN", cfg_get_in_cmd_templates(cfg, "LLAMA_BIN"));
        if (kv["LLAMA_BIN"].empty()) kv["LLAMA_BIN"] = cfg_get_model_field(cfg, model.empty()?"llm_20b":model, "bin");
    }
    if (kv["MODEL_PATH"].empty()) {
        kv["MODEL_PATH"] = cfg_get(cfg, "MODEL_PATH", cfg_get_in_cmd_templates(cfg, "MODEL_PATH"));
        if (kv["MODEL_PATH"].empty()) kv["MODEL_PATH"] = cfg_get_model_field(cfg, model.empty()?"llm_20b":model, "path");
    }

    std::string cmd = build_cmd(tmpl, kv);
    write_file(log, std::string("chat cmd: ")+cmd+"\n");

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        std::string s = std::string("{\"op\":\"error\",\"jobid\":\"") + jobid + "\",\"error\":\"pipe failed\"}\n";
        ::write(client_fd, s.c_str(), s.size());
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        std::string s = std::string("{\"op\":\"error\",\"jobid\":\"") + jobid + "\",\"error\":\"fork failed\"}\n";
        ::write(client_fd, s.c_str(), s.size());
        close(pipefd[0]); close(pipefd[1]);
        return;
    }

    if (pid == 0) {
        // child
        ::close(pipefd[0]);
        // stdout をパイプに繋ぐ
        ::dup2(pipefd[1], STDOUT_FILENO);
        ::dup2(pipefd[1], STDERR_FILENO); // エラーも流す
        // シェル経由で実行（テンプレ展開済み）
        execl("/bin/sh", "sh", "-lc", cmd.c_str(), (char*)nullptr);
        _exit(127);
    }
    // parent
    ::close(pipefd[1]);
    {
        std::lock_guard<std::mutex> lk(g_chat_mtx);
        g_chat_pids[jobid] = pid;
    }

    // started 通知
    {
        std::ostringstream oss; oss << "{\"op\":\"chat_started\",\"jobid\":\"" << jobid << "\"}" << "\n";
        auto s = oss.str();
        ::write(client_fd, s.c_str(), s.size());
    }

    // 読み取りスレッド: 逐次 token イベント送信
    std::thread([client_fd, pid, rfd=pipefd[0], jobid, log]() mutable {
        char buf[1024];
        std::string partial;
        while (true) {
            ssize_t n = ::read(rfd, buf, sizeof(buf));
            if (n > 0) {
                // バッファを改行で区切りつつ送信
                partial.append(buf, buf+n);
                size_t pos = 0;
                while (true) {
                    auto nl = partial.find('\n', pos);
                    if (nl == std::string::npos) break;
                    std::string line = partial.substr(pos, nl - pos);
                    pos = nl + 1;
                    if (!line.empty()) {
                        std::ostringstream tok;
                        tok << "{\"op\":\"token\",\"jobid\":\"" << jobid << "\",\"data\":";
                        // JSONエスケープ（最小）
                        std::string esc; esc.reserve(line.size()+8);
                        for (char c: line) { if (c=='"' || c=='\\') esc.push_back('\\'); esc.push_back(c); }
                        tok << "\"" << esc << "\"}" << "\n";
                        auto s = tok.str();
                        ::write(client_fd, s.c_str(), s.size());
                        // ログにも残す（軽量）
                        std::string l = "token: "+line+"\n";
                        int fd = ::open(log.string().c_str(), O_WRONLY|O_CREAT|O_APPEND, 0644);
                        if (fd>=0) { ::write(fd, l.c_str(), l.size()); ::close(fd); }
                    }
                }
                if (pos > 0) partial.erase(0, pos);
                continue;
            }
            if (n == 0) break; // EOF
            if (errno == EINTR) continue;
            break; // read error
        }
        ::close(rfd);
        int status=0; waitpid(pid, &status, 0);
        int exitc = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128+WTERMSIG(status) : status);
        // done イベント
        std::ostringstream done; done << "{\"op\":\"done\",\"jobid\":\""<<jobid<<"\",\"exit\":"<<exitc<<"}" << "\n";
        auto s = done.str(); ::write(client_fd, s.c_str(), s.size());
        // pid 管理から削除
        std::lock_guard<std::mutex> lk(g_chat_mtx);
        g_chat_pids.erase(jobid);
    }).detach();
}

static void handle_cancel_chat(const std::string& req, int client_fd) {
    std::string jobid = json_get_string(req, "jobid");
    if (jobid.empty()) {
        std::string s = "{\"status\":\"error\",\"message\":\"missing jobid\"}\n"; ::write(client_fd, s.c_str(), s.size()); return;
    }
    pid_t pid = -1;
    {
        std::lock_guard<std::mutex> lk(g_chat_mtx);
        auto it = g_chat_pids.find(jobid);
        if (it != g_chat_pids.end()) pid = it->second;
    }
    if (pid > 0) {
        kill(pid, SIGTERM);
        std::string s = std::string("{\"status\":\"ok\",\"jobid\":\"") + jobid + "\"}\n"; ::write(client_fd, s.c_str(), s.size());
    } else {
        std::string s = std::string("{\"status\":\"error\",\"jobid\":\"") + jobid + "\",\"message\":\"not found\"}\n"; ::write(client_fd, s.c_str(), s.size());
    }
}

static void handle_generate_image(const std::string& req, int client_fd, const std::string& cfg) {
    std::string prompt = json_get_string(req, "prompt");
    std::string neg = json_get_string(req, "negative_prompt");
    int steps = json_get_int(req, "steps", json_get_int(req, "num_inference_steps", 20));
    int w = json_get_int(req, "w", 768);
    int h = json_get_int(req, "h", 768);
    int seed = json_get_int(req, "seed", 42);

    std::string jobid = now_id();
    fs::path jobdir = fs::path(outputs_base_from_cfg(cfg))/jobid;
    fs::create_directories(jobdir);
    fs::path out_png = jobdir/"image_0001.png";
    fs::path log = jobdir/"log.txt";
    write_file(jobdir/"meta.json", std::string("{\n  \"engine\": \"sdxl\", \"w\": ")+std::to_string(w)+", \"h\": "+std::to_string(h)+"\n}\n");

    // Try primary SD template, then alternates (diffusers/sd_cpp keys) if provided
    std::string tmpl = cfg_get(cfg, "SD_CMD_TEMPLATE", "");
    if (tmpl.empty()) tmpl = cfg_get(cfg, "sd_diffusers", "");
    if (tmpl.empty()) tmpl = cfg_get(cfg, "sd_cpp_cli", "");
    std::map<std::string,std::string> kv = {
        {"OUT_DIR", jobdir.string()},
        {"OUT_PNG", out_png.string()},
        {"PROMPT", escape_quotes(prompt)},
        {"NEG_PROMPT", escape_quotes(neg)},
        {"STEPS", std::to_string(steps)},
        {"W", std::to_string(w)},
        {"H", std::to_string(h)},
        {"SEED", std::to_string(seed)}
    };
    // best-effort: pick first model_dir from config if present
    {
        std::string modelDir = cfg_get(cfg, "model_dir", "");
        if (!modelDir.empty()) kv["MODEL_DIR"] = modelDir;
    }
    std::string cmd = build_cmd(tmpl, kv);

    // run synchronously per acceptance
    write_file(log, std::string("cmd: ")+cmd+"\n");
    int rc = run_system_logged(cmd, log);
    std::string status = (rc==0 && fs::exists(out_png)) ? "ok" : "error";
    if (status == "ok") {
        std::ostringstream resp;
        resp << "{\"status\":\"ok\",\"jobid\":\""<<jobid<<"\",\"image\":\""<<out_png.string()<<"\",\"meta\":{\"engine\":\"sdxl\"}}\n";
        auto s = resp.str();
        ::write(client_fd, s.c_str(), s.size());
    } else {
        std::ostringstream resp;
        resp << "{\"status\":\"error\",\"jobid\":\""<<jobid<<"\",\"message\":\"image generation failed rc="<<rc<<"\"}\n";
        auto s = resp.str();
        ::write(client_fd, s.c_str(), s.size());
    }
}

static void video_worker(const std::string jobid, std::string cmd, fs::path log) {
    {
        std::lock_guard<std::mutex> lk(g_jobs_mtx);
        auto it = g_jobs.find(jobid);
        if (it != g_jobs.end()) it->second.running = true;
    }
    int rc = run_system_logged(cmd, log);
    {
        std::lock_guard<std::mutex> lk(g_jobs_mtx);
        auto it = g_jobs.find(jobid);
        if (it != g_jobs.end()) {
            auto &ref = it->second;
            ref.running = false;
            ref.done = (rc==0) && fs::exists(ref.outPath);
            ref.error = !ref.done;
            ref.exitCode = rc;
            int cur = ref.progress.load();
            ref.progress.store(ref.done ? 100 : cur);
        }
    }
}

static void handle_submit_video(const std::string& req, int client_fd, const std::string& cfg) {
    std::string prompt = json_get_string(req, "prompt");
    std::string init_image = json_get_string(req, "init_image");
    std::string motion = json_get_string(req, "motion_module");
    int frames = json_get_int(req, "frames", 16);

    std::string jobid = now_id();
    fs::path jobdir = fs::path(outputs_base_from_cfg(cfg))/jobid;
    fs::create_directories(jobdir);
    fs::path out_mp4 = jobdir/"out.mp4";
    fs::path log = jobdir/"log.txt";
    write_file(jobdir/"meta.json", std::string("{\n  \"engine\": \"animatediff\", \"frames\": ")+std::to_string(frames)+"\n}\n");

    std::string tmpl = cfg_get(cfg, "VIDEO_CMD_TEMPLATE", "");
    if (tmpl.empty()) tmpl = cfg_get(cfg, "animatediff", "");
    std::map<std::string,std::string> kv = {
        {"OUT_DIR", jobdir.string()},
        {"OUT_MP4", out_mp4.string()},
        {"PROMPT", escape_quotes(prompt)},
        {"INIT_IMAGE", init_image},
        {"FRAMES", std::to_string(frames)},
        {"MOTION_MODULE", motion}
    };
    {
        std::string modelDir = cfg_get(cfg, "model_dir", "");
        if (!modelDir.empty()) kv["MODEL_DIR"] = modelDir;
    }
    std::string cmd = build_cmd(tmpl, kv);

    {
        std::lock_guard<std::mutex> lk(g_jobs_mtx);
        JobInfo &ref = g_jobs[jobid];
        ref.id = jobid;
        ref.type = "video";
        ref.dir = jobdir.string();
        ref.outPath = out_mp4.string();
        ref.progress.store(0);
        ref.running.store(true);
        ref.done.store(false);
        ref.error.store(false);
        ref.exitCode = 0;
    }
    write_file(log, std::string("cmd: ")+cmd+"\n");
    std::thread(video_worker, jobid, cmd, log).detach();

    std::ostringstream resp;
    resp << "{\"status\":\"queued\",\"jobid\":\""<<jobid<<"\",\"out\":\""<<out_mp4.string()<<"\"}\n";
    auto s = resp.str();
    ::write(client_fd, s.c_str(), s.size());
}

static void handle_job_status(const std::string& req, int client_fd) {
    std::string jobid = json_get_string(req, "jobid");
    std::lock_guard<std::mutex> lk(g_jobs_mtx);
    auto it = g_jobs.find(jobid);
    if (it == g_jobs.end()) {
        std::string s = "{\"status\":\"error\",\"message\":\"unknown job\"}\n";
        ::write(client_fd, s.c_str(), s.size());
        return;
    }
    const JobInfo &ji = it->second;
    std::string st = ji.error ? "error" : (ji.done ? "done" : (ji.running ? "running" : "queued"));
    std::ostringstream resp;
    resp << "{\"status\":\""<<st<<"\",\"progress\":"<<ji.progress.load()<<",\"out\":\""<<ji.outPath<<"\"}\n";
    auto s = resp.str();
    ::write(client_fd, s.c_str(), s.size());
}

static void serve_client(int cfd, const std::string& cfg) {
    std::string line; line.reserve(4096);
    char buf[1024];
    while (true) {
        ssize_t n = ::read(cfd, buf, sizeof(buf));
        if (n <= 0) break;
        for (ssize_t i=0;i<n;i++) {
            if (buf[i]=='\n') {
                // process a line
                std::string req = line;
                line.clear();
                std::string op = json_get_string(req, "op");
                if (op == "generate_image") {
                    handle_generate_image(req, cfd, cfg);
                } else if (op == "submit_video") {
                    handle_submit_video(req, cfd, cfg);
                } else if (op == "job_status") {
                    handle_job_status(req, cfd);
                } else if (op == "start_chat") {
                    handle_start_chat(req, cfd, cfg);
                } else if (op == "stop_chat" || op == "cancel") {
                    handle_cancel_chat(req, cfd);
                } else if (op == "vqa") {
                    // vqa_blip2 テンプレートを実行して単一回答を返す（同期）
                    std::string image = json_get_string(req, "image");
                    std::string question = json_get_string(req, "question");
                    std::string tmpl = cfg_get(cfg, "vqa_blip2", "");
                    if (tmpl.empty()) tmpl = cfg_get_in_cmd_templates(cfg, "vqa_blip2");
                    if (tmpl.empty()) {
                        std::string s = "{\"op\":\"error\",\"error\":\"vqa_blip2 template missing\"}\n"; ::write(cfd, s.c_str(), s.size());
                    } else {
                        std::map<std::string,std::string> kv {{"IMAGE", image},{"QUESTION", escape_quotes(question)}};
                        std::string cmd = build_cmd(tmpl, kv);
                        fs::path log = fs::path(outputs_base_from_cfg(cfg))/"vqa.log";
                        int rc = run_system_logged(cmd, log);
                        if (rc==0) {
                            // スクリプトは JSON を標準出力する想定。最終行をそのまま中継。
                            std::string out = read_file(log);
                            std::string answer;
                            // 最後の { から抽出する乱暴な方法
                            auto p = out.rfind('{');
                            if (p!=std::string::npos) answer = out.substr(p);
                            if (answer.empty()) answer = std::string("{\"op\":\"done\",\"answer\":\"unknown\"}");
                            if (answer.back()!='\n') answer.push_back('\n');
                            ::write(cfd, answer.c_str(), answer.size());
                        } else {
                            std::string s = std::string("{\"op\":\"error\",\"error\":\"vqa failed rc=") + std::to_string(rc) + "\"}\n"; ::write(cfd, s.c_str(), s.size());
                        }
                    }
                } else if (op == "rag_index" || op == "rag_query") {
                    // rag worker ラッパー
                    std::string subop = (op=="rag_index")?"index":"query";
                    std::string tmpl = cfg_get(cfg, "rag", "");
                    if (tmpl.empty()) tmpl = cfg_get_in_cmd_templates(cfg, "rag");
                    if (tmpl.empty()) {
                        std::string s = "{\"op\":\"error\",\"error\":\"rag template missing\"}\n"; ::write(cfd, s.c_str(), s.size());
                    } else {
                        std::string folder = json_get_string(req, "folder");
                        std::string query = json_get_string(req, "query");
                        std::string topk = std::to_string(json_get_int(req, "topk", 5));
                        std::map<std::string,std::string> kv {{"SUBOP", subop},{"RAG_ROOT", folder},{"QUERY", escape_quotes(query)},{"TOPK", topk}};
                        std::string cmd = build_cmd(tmpl, kv);
                        fs::path log = fs::path(outputs_base_from_cfg(cfg))/"rag.log";
                        int rc = run_system_logged(cmd, log);
                        if (rc==0) {
                            std::string out = read_file(log);
                            // 最後の { から JSON を推定
                            auto p = out.rfind('{');
                            std::string js; if (p!=std::string::npos) js = out.substr(p);
                            if (js.empty()) js = std::string("{\"op\":\"done\",\"chunks\":[]}\n");
                            if (js.back()!='\n') js.push_back('\n');
                            ::write(cfd, js.c_str(), js.size());
                        } else {
                            std::string s = std::string("{\"op\":\"error\",\"error\":\"rag ")+subop+" failed rc="+std::to_string(rc)+"\"}\n"; ::write(cfd, s.c_str(), s.size());
                        }
                    }
                } else {
                    std::string s = "{\"status\":\"error\",\"message\":\"unknown op\"}\n";
                    ::write(cfd, s.c_str(), s.size());
                }
            } else {
                line.push_back(buf[i]);
            }
        }
    }
    ::close(cfd);
}

int main() {
    // prepare socket
    ::unlink(SOCK_PATH);
    int sfd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) { std::perror("socket"); return 1; }
    sockaddr_un addr{}; addr.sun_family = AF_UNIX; std::strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path)-1);
    if (::bind(sfd, (sockaddr*)&addr, sizeof(addr))<0) { std::perror("bind"); return 1; }
    if (::listen(sfd, 8)<0) { std::perror("listen"); return 1; }
    // load config
    std::string cfg = load_config_or_default();

    while (true) {
        int cfd = ::accept(sfd, nullptr, nullptr);
        if (cfd<0) { if (errno==EINTR) continue; std::perror("accept"); break; }
        std::thread(serve_client, cfd, cfg).detach();
    }
    ::close(sfd);
    ::unlink(SOCK_PATH);
    return 0;
}
