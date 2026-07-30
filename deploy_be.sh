#!/bin/bash

# ============================================================
# deploy_be.sh - 把本地的 be/bin、be/lib 部署到远端机器
#
# 单台机器的部署流程（在远端执行）：
#   1. scp bin/ lib/ 到远端临时目录（上传失败则不停 BE）
#   2. ./bin/stop_be.sh，等待 starrocks_be 进程真正退出
#   3. 把旧的 bin/lib 移动到备份目录
#   4. 用新的 bin/lib 覆盖
#   5. ./bin/start_be.sh --daemon
#   6. 确认进程存活 + HTTP /api/health 正常
#   7. 任一步失败（且 ROLLBACK=1）自动回滚到备份版本并重新拉起
#
# 多台机器串行滚动部署，默认某台失败即停止。
# ============================================================

set -uo pipefail

# ---- 配置项（均可用环境变量覆盖）----
LOCAL_BE="${LOCAL_BE:-./be}"        # 本地 be 目录（需包含 bin/ 和 lib/）
REMOTE_BE="${REMOTE_BE:-}"          # 远端 be 目录，必填（或用 -d 指定）
HOSTS="${HOSTS:-}"                  # 目标机器，逗号或空格分隔（或用 -H / -f / 位置参数）
SSH_USER="${SSH_USER:-}"            # ssh 用户名，留空表示用当前用户/ssh config
SSH_PORT="${SSH_PORT:-}"           # ssh 端口，留空表示默认
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=10}"
SCP_COMPRESS="${SCP_COMPRESS:-1}"   # scp 传输压缩（-C），0 关闭

STOP_TIMEOUT="${STOP_TIMEOUT:-120}"   # 等待 starrocks_be 退出的最长时间（秒）
START_TIMEOUT="${START_TIMEOUT:-180}" # 等待启动成功的最长时间（秒）
STABLE_WAIT="${STABLE_WAIT:-10}"      # 进程起来后再观察多久，防止起来就崩
FORCE_KILL="${FORCE_KILL:-0}"         # 停止超时后是否 kill -9
ROLLBACK="${ROLLBACK:-1}"             # 部署失败是否自动回滚
HEALTH_PORT="${HEALTH_PORT:-auto}"    # BE http 端口；auto=从 be.conf 读取，0=跳过健康检查
BACKUP_KEEP="${BACKUP_KEEP:-5}"       # 远端保留的备份份数

CONTINUE_ON_ERROR=0
ASSUME_YES=0
DRY_RUN=0

# ---- 日志函数 ----
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "错误: $*"
    exit 1
}

usage() {
    cat <<'EOF'
用法: ./deploy_be.sh [选项] [host ...]

选项:
  -s <dir>    本地 be 目录，需包含 bin/ 和 lib/         (默认 ./be，或 LOCAL_BE)
  -d <dir>    远端 be 目录（必填，或 REMOTE_BE）
  -H <hosts>  目标机器，逗号/空格分隔（或 HOSTS，或位置参数）
  -f <file>   从文件读取机器列表，一行一个，# 开头为注释
  -u <user>   ssh 用户名                                (或 SSH_USER)
  -p <port>   ssh 端口                                  (或 SSH_PORT)
  -y          跳过确认
  -k          停止超时后 kill -9                        (等价 FORCE_KILL=1)
  -c          某台失败后继续部署其余机器
  -n          只打印计划，不实际执行
  -h          显示帮助

环境变量: STOP_TIMEOUT START_TIMEOUT STABLE_WAIT ROLLBACK HEALTH_PORT
          BACKUP_KEEP SSH_OPTS SCP_COMPRESS

示例:
  REMOTE_BE=/data/starrocks/be ./deploy_be.sh -s ~/starrocks/output/be be01 be02
  ./deploy_be.sh -s ./be -d /data/starrocks/be -f hosts.txt -y
  HEALTH_PORT=0 ./deploy_be.sh -d /data/starrocks/be be01     # 跳过 http 健康检查
EOF
}

# ---- 参数解析 ----
HOST_FILE=""
while getopts ":s:d:H:f:u:p:ykcnh" opt; do
    case "$opt" in
        s) LOCAL_BE="$OPTARG" ;;
        d) REMOTE_BE="$OPTARG" ;;
        H) HOSTS="$OPTARG" ;;
        f) HOST_FILE="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        p) SSH_PORT="$OPTARG" ;;
        y) ASSUME_YES=1 ;;
        k) FORCE_KILL=1 ;;
        c) CONTINUE_ON_ERROR=1 ;;
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        \?) usage; die "未知选项: -$OPTARG" ;;
        :) usage; die "选项 -$OPTARG 需要参数" ;;
    esac
done
shift $((OPTIND - 1))

# 位置参数追加到主机列表
if [ $# -gt 0 ]; then
    HOSTS="$HOSTS $*"
fi

if [ -n "$HOST_FILE" ]; then
    [ -f "$HOST_FILE" ] || die "主机列表文件不存在: $HOST_FILE"
    HOSTS="$HOSTS $(grep -v '^[[:space:]]*#' "$HOST_FILE" | tr '\n' ' ')"
fi

# 逗号也当分隔符
read -r -a HOST_LIST <<< "$(echo "$HOSTS" | tr ',' ' ')"

[ "${#HOST_LIST[@]}" -gt 0 ] || { usage; die "未指定目标机器"; }

# getopts 遇到第一个非选项就停止解析，选项必须写在主机名前面
for h in "${HOST_LIST[@]}"; do
    case "$h" in
        -*) die "选项 $h 必须写在主机名之前，例如: ./deploy_be.sh -d /data/be -c be01 be02" ;;
    esac
done
[ -n "$REMOTE_BE" ] || { usage; die "未指定远端 be 目录（-d 或 REMOTE_BE）"; }
case "$REMOTE_BE" in
    /*) ;;
    *) die "远端 be 目录必须是绝对路径: $REMOTE_BE" ;;
esac

# ---- 检查本地目录 ----
[ -d "$LOCAL_BE" ] || die "本地 be 目录不存在: $LOCAL_BE"
[ -d "$LOCAL_BE/bin" ] || die "本地缺少目录: $LOCAL_BE/bin"
[ -d "$LOCAL_BE/lib" ] || die "本地缺少目录: $LOCAL_BE/lib"
[ -f "$LOCAL_BE/bin/start_be.sh" ] || die "本地缺少文件: $LOCAL_BE/bin/start_be.sh"
[ -f "$LOCAL_BE/bin/stop_be.sh" ] || die "本地缺少文件: $LOCAL_BE/bin/stop_be.sh"
[ -f "$LOCAL_BE/lib/starrocks_be" ] || die "本地缺少文件: $LOCAL_BE/lib/starrocks_be"

TS="$(date '+%Y%m%d_%H%M%S')"
STAGE="/tmp/be_deploy_$TS"

SSH_TARGET_PREFIX=""
[ -n "$SSH_USER" ] && SSH_TARGET_PREFIX="$SSH_USER@"
# 故意不加引号展开，SSH_OPTS 里是多个选项
SSH_CMD="ssh $SSH_OPTS"
SCP_CMD="scp $SSH_OPTS"
if [ -n "$SSH_PORT" ]; then
    SSH_CMD="$SSH_CMD -p $SSH_PORT"
    SCP_CMD="$SCP_CMD -P $SSH_PORT"
fi
[ "$SCP_COMPRESS" = 1 ] && SCP_CMD="$SCP_CMD -C"

COPY_SIZE="$(du -shc "$LOCAL_BE/bin" "$LOCAL_BE/lib" 2>/dev/null | tail -1 | awk '{print $1}')"

# ---- 部署计划 ----
log "本地目录 : $(cd "$LOCAL_BE" && pwd)  (bin+lib 共 $COPY_SIZE)"
log "远端目录 : $REMOTE_BE"
log "目标机器 : ${HOST_LIST[*]}"
log "备份目录 : $REMOTE_BE/deploy_backup/$TS (保留最近 $BACKUP_KEEP 份)"
log "参数     : STOP_TIMEOUT=${STOP_TIMEOUT}s START_TIMEOUT=${START_TIMEOUT}s" \
    "STABLE_WAIT=${STABLE_WAIT}s FORCE_KILL=$FORCE_KILL ROLLBACK=$ROLLBACK HEALTH_PORT=$HEALTH_PORT"

if [ "$DRY_RUN" = 1 ]; then
    log "dry-run 模式，未执行任何操作"
    exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
    printf '将重启以上 %d 台机器的 BE，确认继续? [y/N] ' "${#HOST_LIST[@]}"
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) die "已取消" ;;
    esac
fi

# ---- 生成远端执行脚本 ----
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

REMOTE_SH="$WORK_DIR/remote_deploy.sh"
cat > "$REMOTE_SH" <<'REMOTE_EOF'
#!/bin/bash
# 由 deploy_be.sh 上传并在目标机器上执行
set -uo pipefail

: "${BE_HOME:?BE_HOME 未传入}" "${STAGE:?STAGE 未传入}" "${TS:?TS 未传入}"
NEW="$STAGE"          # scp 上传的新版本 bin/ lib/ 就在这里
BACKUP_DIR="$BE_HOME/deploy_backup/$TS"

log() {
    echo "  [$(hostname -s) $(date '+%H:%M:%S')] $*"
}

die() {
    log "错误: $*"
    exit 1
}

# 属于本 BE_HOME 的 starrocks_be 进程号（同机多实例时不误伤其它实例）
be_pids() {
    local pids="" p exe cwd
    for p in $(pgrep -x starrocks_be 2>/dev/null); do
        exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
        cwd="$(readlink "/proc/$p/cwd" 2>/dev/null)"
        if [ -z "$exe" ] && [ -z "$cwd" ]; then
            # 读不到 /proc 信息（权限不足等），保守地当成本实例
            pids="$pids $p"
        elif [ "${exe#$BE_HOME/}" != "$exe" ] || [ "${cwd#$BE_HOME}" != "$cwd" ]; then
            pids="$pids $p"
        fi
    done
    echo "${pids# }"
}

wait_exit() {
    local timeout="$1" waited=0
    while [ -n "$(be_pids)" ]; do
        [ "$waited" -ge "$timeout" ] && return 1
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

# BE http 端口：auto 时从 be.conf 读取，读不到用 8040
resolve_http_port() {
    local port="$HEALTH_PORT"
    if [ "$port" = "auto" ]; then
        port="$(grep -E '^[[:space:]]*be_http_port[[:space:]]*=' "$BE_HOME/conf/be.conf" 2>/dev/null \
                | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
        [ -n "$port" ] || port=8040
    fi
    echo "$port"
}

dump_be_out() {
    local out="$BE_HOME/log/be.out"
    [ -f "$out" ] || return 0
    log "----- $out 最后 30 行 -----"
    tail -n 30 "$out" | sed 's/^/  | /'
    log "----------------------------"
}

start_be() {
    log "启动: ./bin/start_be.sh --daemon"
    ( cd "$BE_HOME" && ./bin/start_be.sh --daemon )
}

# 等进程起来 -> 观察 STABLE_WAIT -> http 健康检查
verify_be() {
    local waited=0 pids port code
    while :; do
        pids="$(be_pids)"
        [ -n "$pids" ] && break
        if [ "$waited" -ge "$START_TIMEOUT" ]; then
            log "starrocks_be 进程未出现（等待 ${waited}s）"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "starrocks_be 已启动, pid=$pids"

    if [ "$STABLE_WAIT" -gt 0 ]; then
        sleep "$STABLE_WAIT"
        pids="$(be_pids)"
        if [ -z "$pids" ]; then
            log "starrocks_be 启动后 ${STABLE_WAIT}s 内退出"
            return 1
        fi
        log "观察 ${STABLE_WAIT}s 后进程仍存活, pid=$pids"
    fi

    port="$(resolve_http_port)"
    if [ "$port" = "0" ]; then
        log "已跳过 http 健康检查"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log "警告: 未安装 curl，跳过 http 健康检查"
        return 0
    fi

    while :; do
        code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
                "http://127.0.0.1:$port/api/health" 2>/dev/null)"
        if [ "$code" = "200" ]; then
            log "健康检查通过: http://127.0.0.1:$port/api/health"
            return 0
        fi
        if [ -z "$(be_pids)" ]; then
            log "健康检查期间进程已退出"
            return 1
        fi
        if [ "$waited" -ge "$START_TIMEOUT" ]; then
            log "健康检查超时（${waited}s），最后 http code=${code:-none}"
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
}

# 回滚：丢弃新版本，恢复备份目录里的 bin/lib，并重新拉起
rollback() {
    log "开始回滚到备份: $BACKUP_DIR"
    if [ ! -d "$BACKUP_DIR/bin" ] || [ ! -d "$BACKUP_DIR/lib" ]; then
        log "备份不完整，无法回滚，请人工处理: $BACKUP_DIR"
        return 1
    fi
    ( cd "$BE_HOME" && ./bin/stop_be.sh >/dev/null 2>&1 )
    if ! wait_exit 60; then
        log "回滚前进程未退出，kill -9 $(be_pids)"
        kill -9 $(be_pids) 2>/dev/null
        sleep 5
    fi
    rm -rf "$BE_HOME/bin" "$BE_HOME/lib"
    mv "$BACKUP_DIR/bin" "$BE_HOME/bin" || { log "恢复 bin 失败"; return 1; }
    mv "$BACKUP_DIR/lib" "$BE_HOME/lib" || { log "恢复 lib 失败"; return 1; }
    rmdir "$BACKUP_DIR" 2>/dev/null
    start_be
    if verify_be; then
        log "回滚完成，已恢复到旧版本"
    else
        log "回滚后启动仍失败，请人工处理"
        return 1
    fi
    return 0
}

fail_after_backup() {
    log "部署失败: $1"
    dump_be_out
    if [ "$ROLLBACK" = "1" ]; then
        rollback
    else
        log "ROLLBACK=0，未回滚。备份在 $BACKUP_DIR"
    fi
    exit 1
}

# ---- 1. 前置检查（此时还没停 BE）----
[ -d "$BE_HOME" ] || die "远端目录不存在: $BE_HOME"
[ -x "$BE_HOME/bin/stop_be.sh" ] || die "缺少可执行文件: $BE_HOME/bin/stop_be.sh"
[ -x "$BE_HOME/bin/start_be.sh" ] || die "缺少可执行文件: $BE_HOME/bin/start_be.sh"
[ -d "$BE_HOME/lib" ] || die "缺少目录: $BE_HOME/lib"

[ -d "$NEW/bin" ] || die "上传的 bin 目录不存在: $NEW/bin"
[ -d "$NEW/lib" ] || die "上传的 lib 目录不存在: $NEW/lib"
[ -f "$NEW/bin/start_be.sh" ] || die "上传内容缺少 bin/start_be.sh"
[ -f "$NEW/lib/starrocks_be" ] || die "上传内容缺少 lib/starrocks_be"
chmod +x "$NEW"/bin/*.sh "$NEW/lib/starrocks_be" 2>/dev/null
log "待部署的 bin/ lib/ 已就绪于 $NEW"

# ---- 2. 停止 BE 并确认进程退出 ----
PIDS_BEFORE="$(be_pids)"
if [ -z "$PIDS_BEFORE" ]; then
    log "starrocks_be 当前未运行，仍执行一次 stop_be.sh"
else
    log "当前 starrocks_be pid=$PIDS_BEFORE"
fi
( cd "$BE_HOME" && ./bin/stop_be.sh ) || log "stop_be.sh 返回非 0，继续等待进程退出"

if ! wait_exit "$STOP_TIMEOUT"; then
    if [ "$FORCE_KILL" = "1" ]; then
        log "等待 ${STOP_TIMEOUT}s 未退出，kill -9 $(be_pids)"
        kill -9 $(be_pids) 2>/dev/null
        wait_exit 30 || die "kill -9 后进程仍存在: $(be_pids)"
    else
        die "等待 starrocks_be 退出超时 (${STOP_TIMEOUT}s), pid=$(be_pids)；可加 -k 强制 kill"
    fi
fi
log "starrocks_be 已完全退出"

# ---- 3. 备份旧的 bin / lib ----
mkdir -p "$BACKUP_DIR" || die "无法创建备份目录: $BACKUP_DIR"
if [ -e "$BACKUP_DIR/bin" ] || [ -e "$BACKUP_DIR/lib" ]; then
    die "备份目录已有内容，可能是同一时间戳重复部署: $BACKUP_DIR"
fi
mv "$BE_HOME/bin" "$BACKUP_DIR/bin" || die "备份 bin 失败"
if ! mv "$BE_HOME/lib" "$BACKUP_DIR/lib"; then
    mv "$BACKUP_DIR/bin" "$BE_HOME/bin"
    die "备份 lib 失败，已把 bin 放回原位"
fi
log "已备份旧 bin/lib 到 $BACKUP_DIR"

# ---- 4. 覆盖为新版本 ----
if ! mv "$NEW/bin" "$BE_HOME/bin"; then
    rm -rf "$BE_HOME/bin"
    mv "$BACKUP_DIR/bin" "$BE_HOME/bin"
    mv "$BACKUP_DIR/lib" "$BE_HOME/lib"
    die "写入新 bin 失败，已恢复旧版本"
fi
if ! mv "$NEW/lib" "$BE_HOME/lib"; then
    fail_after_backup "写入新 lib 失败"
fi
log "新 bin/lib 已就位"

# ---- 5. 启动 ----
if ! start_be; then
    fail_after_backup "start_be.sh 返回非 0"
fi

# ---- 6. 确认启动正常 ----
if ! verify_be; then
    fail_after_backup "启动校验未通过"
fi

# ---- 7. 清理旧备份 ----
if [ "$BACKUP_KEEP" -gt 0 ]; then
    old="$(ls -1dt "$BE_HOME/deploy_backup"/*/ 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)))"
    if [ -n "$old" ]; then
        echo "$old" | while read -r d; do
            log "清理旧备份: $d"
            rm -rf "$d"
        done
    fi
fi

log "部署成功"
REMOTE_EOF

# 在单台机器上跑完整流程，返回非 0 表示该机器失败
deploy_one() {
    local host="$1"
    local target="$SSH_TARGET_PREFIX$host"

    if ! $SSH_CMD "$target" "mkdir -p '$STAGE'"; then
        log "$host: 无法连接或创建临时目录 $STAGE"
        return 1
    fi

    log "$host: scp bin/ lib/ -> $STAGE/ ($COPY_SIZE)"
    if ! $SCP_CMD -r "$LOCAL_BE/bin" "$LOCAL_BE/lib" "$REMOTE_SH" "$target:$STAGE/"; then
        log "$host: 上传失败"
        $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
        return 1
    fi
    log "$host: 上传完成"

    local rc=0
    $SSH_CMD "$target" \
        "BE_HOME='$REMOTE_BE' STAGE='$STAGE' TS='$TS' \
         STOP_TIMEOUT='$STOP_TIMEOUT' START_TIMEOUT='$START_TIMEOUT' \
         STABLE_WAIT='$STABLE_WAIT' FORCE_KILL='$FORCE_KILL' \
         ROLLBACK='$ROLLBACK' HEALTH_PORT='$HEALTH_PORT' \
         BACKUP_KEEP='$BACKUP_KEEP' \
         bash '$STAGE/remote_deploy.sh'" || rc=$?

    $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
    return $rc
}

# ---- 逐台串行部署 ----
OK_HOSTS=""
FAIL_HOSTS=""
OK_COUNT=0
FAIL_COUNT=0
ABORTED=""

for host in "${HOST_LIST[@]}"; do
    echo
    log "======== $host 开始部署 ========"
    if deploy_one "$host"; then
        log "======== $host 部署成功 ========"
        OK_HOSTS="$OK_HOSTS $host"
        OK_COUNT=$((OK_COUNT + 1))
    else
        log "======== $host 部署失败 ========"
        FAIL_HOSTS="$FAIL_HOSTS $host"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        if [ "$CONTINUE_ON_ERROR" != 1 ]; then
            ABORTED=1
            log "已中止后续机器（加 -c 可继续）"
            break
        fi
    fi
done

# ---- 汇总 ----
echo
log "成功 $OK_COUNT 台:${OK_HOSTS:- 无}"
log "失败 $FAIL_COUNT 台:${FAIL_HOSTS:- 无}"
[ -n "$ABORTED" ] && log "有机器未部署，请检查后重试"
[ "$FAIL_COUNT" -eq 0 ] || exit 1