#!/bin/bash

# ============================================================
# deploy_be.sh - 把本地的 bin、lib 部署到远端 BE / CN 节点
#
# BE 和 CN 用的是同一个二进制（lib/starrocks_be），目录结构也一致，
# 差别只在启停脚本、配置文件和 .out 日志的名字，用 -r be|cn 切换。
#
# 单台机器的部署流程（在远端执行）：
#   1. scp bin/ lib/ 到远端中转目录（上传失败则不停服务）
#      默认放在部署目录的上级目录，和部署目录同一文件系统，mv 是瞬间改名
#   2. ./bin/stop_<role>.sh，等待 starrocks_be 进程真正退出
#   3. 把旧的 bin/lib 移动到备份目录
#   4. 用新的 bin/lib 覆盖
#   5. ./bin/start_<role>.sh --daemon
#   6. 确认进程存活 + HTTP /api/health 正常
#   7. 任一步失败（且 ROLLBACK=1）自动回滚到备份版本并重新拉起
#
# 多台机器串行滚动部署，默认某台失败即停止。
#
# 切换到历史版本：-l 列出每台机器上的备份，-R <时间戳|last> 切换到某份备份。
# 切换时备份先在远端复制到中转目录（不上传），之后流程同上，当前版本也会
# 存成一份新备份，因此可以再切回来。
#
# 修改配置并重启：-C key=value / -U key（可重复）。各机器上先算出新的
# conf/<role>.conf 并打印 diff，无变化的机器跳过；有变化则停服、备份为
# conf/<role>.conf.bak.<ts>、写入、启动、检查，失败自动恢复原配置。
# ============================================================

set -uo pipefail

# ---- 配置项（均可用环境变量覆盖）----
ROLE="${ROLE:-be}"                  # 部署角色: be 或 cn（或用 -r 指定）
LOCAL_BE="${LOCAL_BE:-./be}"        # 本地目录（需包含 bin/ 和 lib/）
REMOTE_BE="${REMOTE_BE:-}"          # 远端部署目录，必填（或用 -d 指定）
STAGE_DIR="${STAGE_DIR:-}"          # 远端中转目录的父目录，留空=部署目录的上级目录（或用 -t 指定）
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
HEALTH_PORT="${HEALTH_PORT:-auto}"    # http 端口；auto=从 <role>.conf 读取，0=跳过健康检查
BACKUP_KEEP="${BACKUP_KEEP:-5}"       # 远端保留的备份份数

CONTINUE_ON_ERROR=0
ASSUME_YES=0
DRY_RUN=0
LIST_BACKUPS=0
RESTORE_TS=""
CONF_EDITS=""          # 每行一条: set<TAB>key<TAB>value 或 unset<TAB>key
SHOW_KEYS=""           # -S: 逗号分隔的配置项，或 all

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
  -r <role>   部署角色: be 或 cn                        (默认 be，或 ROLE)
  -s <dir>    本地目录，需包含 bin/ 和 lib/             (默认 ./be，或 LOCAL_BE)
  -d <dir>    远端部署目录（必填，或 REMOTE_BE）
  -t <dir>    远端中转目录的父目录，上传内容先放在 <dir>/.<role>_deploy_<ts>/
              (默认为部署目录的上级目录，或 STAGE_DIR；建议与部署目录同盘)
  -H <hosts>  目标机器，逗号/空格分隔（或 HOSTS，或位置参数）
  -f <file>   从文件读取机器列表，一行一个，# 开头为注释
  -u <user>   ssh 用户名                                (或 SSH_USER)
  -p <port>   ssh 端口                                  (或 SSH_PORT)
  -y          跳过确认
  -k          停止超时后 kill -9                        (等价 FORCE_KILL=1)
  -c          某台失败后继续部署其余机器
  -n          只打印计划，不实际执行
  -l          列出每台机器上的备份（远端 <部署目录>/deploy_backup/），不做修改
  -R <ts>     切换到某份备份，<ts> 为 -l 列出的时间戳，last 表示最近一份
              (不需要 -s；当前版本会另存一份备份，可以再切回来)
  -C <k=v>    修改 conf/<role>.conf 中的配置项并重启，可重复（不需要 -s）
  -U <key>    注释掉 conf/<role>.conf 中的配置项（恢复默认值）并重启，可重复
              (-C/-U 加 -n 时只打印各机器上的配置 diff，不做修改)
  -S <keys>   查看各机器 conf/<role>.conf 中的配置项，逗号分隔；all 表示全部生效行
              (只读配置文件；运行中的值可能已被 update_config 临时改过)
  -h          显示帮助

环境变量: STOP_TIMEOUT START_TIMEOUT STABLE_WAIT ROLLBACK HEALTH_PORT
          BACKUP_KEEP SSH_OPTS SCP_COMPRESS

示例:
  ./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -f hosts.txt -u sr
  ./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -f hosts.txt -u sr -y -c
  ./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -f hosts.txt -u sr -n   # 只看计划
  ./deploy_be.sh -r cn -s ~/starrocks/output/be -d /home/disk1/sr/cn -f cn_hosts.txt -u sr
  ./deploy_be.sh -s ~/starrocks/output/be -d /home/disk1/sr/be -u sr be01 be02
  ./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -l                  # 列出备份
  ./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -R 20260927_082927  # 切到该备份
  ./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -R last             # 切到最近一份备份
  ./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -S mem_limit,sys_log_level  # 查看配置
  ./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -C mem_limit=80% -n    # 预览配置 diff
  ./deploy_be.sh -d /home/disk1/sr/be -f hosts.txt -u sr -C mem_limit=80% -U sys_log_level
EOF
}

# -C / -U 的参数校验后追加到 CONF_EDITS
add_conf_edit() {
    local op="$1" arg="$2" key value=""
    if [ "$op" = set ]; then
        case "$arg" in
            *=*) ;;
            *) die "-C 需要 key=value 形式: $arg" ;;
        esac
        key="${arg%%=*}"
        value="${arg#*=}"
        # 允许 key = value 这种带空格的写法
        key="$(echo "$key" | tr -d '[:space:]')"
        value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    else
        key="$arg"
    fi
    echo "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_.]*$' || die "配置项名不合法: $key"
    case "$value" in
        *$'\t'*|*$'\n'*) die "配置值不能包含制表符或换行: $key" ;;
    esac
    CONF_EDITS="$CONF_EDITS$op"$'\t'"$key"
    [ "$op" = set ] && CONF_EDITS="$CONF_EDITS"$'\t'"$value"
    CONF_EDITS="$CONF_EDITS"$'\n'
}

# ---- 参数解析 ----
HOST_FILE=""
while getopts ":r:s:d:t:H:f:u:p:ykcnlR:C:U:S:h" opt; do
    case "$opt" in
        r) ROLE="$OPTARG" ;;
        s) LOCAL_BE="$OPTARG" ;;
        d) REMOTE_BE="$OPTARG" ;;
        t) STAGE_DIR="$OPTARG" ;;
        H) HOSTS="$OPTARG" ;;
        f) HOST_FILE="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        p) SSH_PORT="$OPTARG" ;;
        y) ASSUME_YES=1 ;;
        k) FORCE_KILL=1 ;;
        c) CONTINUE_ON_ERROR=1 ;;
        n) DRY_RUN=1 ;;
        l) LIST_BACKUPS=1 ;;
        R) RESTORE_TS="$OPTARG" ;;
        C) add_conf_edit set "$OPTARG" ;;
        U) add_conf_edit unset "$OPTARG" ;;
        S) SHOW_KEYS="$OPTARG" ;;
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
[ -n "$REMOTE_BE" ] || { usage; die "未指定远端部署目录（-d 或 REMOTE_BE）"; }
case "$REMOTE_BE" in
    /*) ;;
    *) die "远端部署目录必须是绝对路径: $REMOTE_BE" ;;
esac
# 去掉末尾的 /，否则 dirname /a/b/ 之类的结果不符合预期
while [ "${REMOTE_BE%/}" != "$REMOTE_BE" ] && [ "$REMOTE_BE" != / ]; do
    REMOTE_BE="${REMOTE_BE%/}"
done
[ "$REMOTE_BE" != / ] || die "远端部署目录不能是 /"

[ -n "$STAGE_DIR" ] || STAGE_DIR="$(dirname "$REMOTE_BE")"
case "$STAGE_DIR" in
    /*) ;;
    *) die "中转目录必须是绝对路径: $STAGE_DIR" ;;
esac
STAGE_DIR="${STAGE_DIR%/}"

case "$ROLE" in
    be|cn) ;;
    *) die "角色只能是 be 或 cn: $ROLE" ;;
esac

MODE=deploy
[ -n "$CONF_EDITS" ] && MODE=config
if [ "$MODE" = config ] && { [ -n "$RESTORE_TS" ] || [ "$LIST_BACKUPS" = 1 ]; }; then
    die "-C/-U 不能和 -R、-l 同时使用"
fi
if [ -n "$SHOW_KEYS" ]; then
    { [ "$MODE" = config ] || [ -n "$RESTORE_TS" ] || [ "$LIST_BACKUPS" = 1 ]; } \
        && die "-S 不能和 -C/-U、-R、-l 同时使用"
    if [ "$SHOW_KEYS" != all ]; then
        for k in $(echo "$SHOW_KEYS" | tr ',' ' '); do
            echo "$k" | grep -qE '^[A-Za-z_][A-Za-z0-9_.]*$' || die "配置项名不合法: $k"
        done
    fi
fi

if [ -n "$RESTORE_TS" ]; then
    [ "$LIST_BACKUPS" = 1 ] && die "-l 和 -R 不能同时使用"
    # 时间戳会拼进远端路径，只接受固定格式
    echo "$RESTORE_TS" | grep -qE '^([0-9]{8}_[0-9]{6}|last)$' \
        || die "-R 需要形如 20260927_082927 的时间戳或 last: $RESTORE_TS"
fi

# ---- 检查本地目录（切换/列出备份/改配置时用不到本地目录）----
# BE 和 CN 共用 lib/starrocks_be，只有启停脚本名不同
if [ "$MODE" = deploy ] && [ -z "$RESTORE_TS" ] && [ "$LIST_BACKUPS" != 1 ] && [ -z "$SHOW_KEYS" ]; then
    [ -d "$LOCAL_BE" ] || die "本地目录不存在: $LOCAL_BE"
    [ -d "$LOCAL_BE/bin" ] || die "本地缺少目录: $LOCAL_BE/bin"
    [ -d "$LOCAL_BE/lib" ] || die "本地缺少目录: $LOCAL_BE/lib"
    [ -f "$LOCAL_BE/bin/start_$ROLE.sh" ] || die "本地缺少文件: $LOCAL_BE/bin/start_$ROLE.sh"
    [ -f "$LOCAL_BE/bin/stop_$ROLE.sh" ] || die "本地缺少文件: $LOCAL_BE/bin/stop_$ROLE.sh"
    [ -f "$LOCAL_BE/lib/starrocks_be" ] || die "本地缺少文件: $LOCAL_BE/lib/starrocks_be"
fi

TS="$(date '+%Y%m%d_%H%M%S')"
STAGE="$STAGE_DIR/.${ROLE}_deploy_$TS"

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

# 远端 deploy_backup/ 下的备份（名字即时间戳），新的在前；用法: bash -s -- <部署目录>
LIST_BACKUPS_SH='
dir="$1/deploy_backup"
names="$(ls -1 "$dir" 2>/dev/null | grep -E "^[0-9]{8}_[0-9]{6}\$" | sort -r)"
if [ -z "$names" ]; then
    echo "    (无备份)"
    exit 0
fi
first=1
for b in $names; do
    t="$(echo "$b" | sed -E "s/^(....)(..)(..)_(..)(..)(..)\$/\1-\2-\3 \4:\5:\6/")"
    size="$(du -sh "$dir/$b" 2>/dev/null | cut -f1)"
    note=""
    [ "$first" = 1 ] && note="  <- last"
    { [ -d "$dir/$b/bin" ] && [ -d "$dir/$b/lib" ]; } || note="$note  (不完整，不能切换)"
    printf "    %s  %s  %6s%s\n" "$b" "$t" "$size" "$note"
    first=0
done
'

if [ "$LIST_BACKUPS" = 1 ]; then
    log "远端目录 : $REMOTE_BE/deploy_backup/"
    log "时间戳是备份生成（即被替换下来）的时间，里面是那次部署之前的版本"
    rc=0
    for host in "${HOST_LIST[@]}"; do
        echo "  $host:"
        $SSH_CMD "$SSH_TARGET_PREFIX$host" bash -s -- "'$REMOTE_BE'" <<< "$LIST_BACKUPS_SH" \
            || { echo "    (无法连接)"; rc=1; }
    done
    exit $rc
fi

# 打印配置文件里的配置项；用法: bash -s -- <配置文件> <key,key|all>
SHOW_CONF_SH='
conf="$1"; keys="$2"
[ -f "$conf" ] || { echo "    (配置文件不存在: $conf)"; exit 1; }
if [ "$keys" = all ]; then
    grep -E "^[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*=" "$conf" | sed "s/^[[:space:]]*/    /"
    exit 0
fi
for k in $(echo "$keys" | tr "," " "); do
    re="$(echo "$k" | sed "s/\./\\\\./g")"
    lines="$(grep -E "^[[:space:]]*$re[[:space:]]*=" "$conf")"
    if [ -z "$lines" ]; then
        echo "    $k  (未设置，使用默认值)"
    else
        echo "$lines" | sed "s/^[[:space:]]*/    /"
        [ "$(echo "$lines" | wc -l)" -gt 1 ] && echo "    ^ $k 出现多次"
    fi
done
exit 0
'

if [ -n "$SHOW_KEYS" ]; then
    log "配置文件 : $REMOTE_BE/conf/$ROLE.conf"
    rc=0
    for host in "${HOST_LIST[@]}"; do
        echo "  $host:"
        $SSH_CMD "$SSH_TARGET_PREFIX$host" bash -s -- "'$REMOTE_BE/conf/$ROLE.conf'" "'$SHOW_KEYS'" \
            <<< "$SHOW_CONF_SH" || { echo "    (失败)"; rc=1; }
    done
    exit $rc
fi

if [ "$MODE" = deploy ] && [ -z "$RESTORE_TS" ]; then
    COPY_SIZE="$(du -shc "$LOCAL_BE/bin" "$LOCAL_BE/lib" 2>/dev/null | tail -1 | awk '{print $1}')"
fi

# ---- 部署计划 ----
log "部署角色 : $(echo "$ROLE" | tr '[:lower:]' '[:upper:]')  (bin/start_$ROLE.sh, conf/$ROLE.conf, log/$ROLE.out)"
if [ "$MODE" = config ]; then
    log "修改配置 : $REMOTE_BE/conf/$ROLE.conf  (原文件备份为 $ROLE.conf.bak.${TS}，保留最近 $BACKUP_KEEP 份)"
    printf '%s' "$CONF_EDITS" | while IFS=$'\t' read -r op key value; do
        if [ "$op" = set ]; then
            log "           $key = $value"
        else
            log "           $key  (注释掉，恢复默认值)"
        fi
    done
elif [ -n "$RESTORE_TS" ]; then
    if [ "$RESTORE_TS" = last ]; then
        log "切换到   : 各机器 $REMOTE_BE/deploy_backup/ 下最近的一份备份  (先在远端复制到中转目录，不上传)"
    else
        log "切换到   : 远端备份 $REMOTE_BE/deploy_backup/$RESTORE_TS  (先在远端复制到中转目录，不上传)"
    fi
else
    log "本地目录 : $(cd "$LOCAL_BE" && pwd)  (bin+lib 共 $COPY_SIZE)"
fi
log "远端目录 : $REMOTE_BE"
log "中转目录 : $STAGE  (部署结束后删除)"
log "目标机器 : ${HOST_LIST[*]}"
[ "$MODE" = deploy ] && log "备份目录 : $REMOTE_BE/deploy_backup/$TS (保留最近 $BACKUP_KEEP 份)"
log "参数     : STOP_TIMEOUT=${STOP_TIMEOUT}s START_TIMEOUT=${START_TIMEOUT}s" \
    "STABLE_WAIT=${STABLE_WAIT}s FORCE_KILL=$FORCE_KILL ROLLBACK=$ROLLBACK HEALTH_PORT=$HEALTH_PORT"

# 改配置的 dry-run 要到各机器上算 diff，不在这里退出
if [ "$DRY_RUN" = 1 ] && [ "$MODE" != config ]; then
    log "dry-run 模式，未执行任何操作"
    exit 0
fi

if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    what=""
    [ -n "$RESTORE_TS" ] && what=" 并切换到备份 $RESTORE_TS"
    [ "$MODE" = config ] && what=" 并修改配置（无变化的机器不重启）"
    printf '将重启以上 %d 台机器的 %s%s，确认继续? [y/N] ' \
        "${#HOST_LIST[@]}" "$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')" "$what"
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
CONF_EDITS_FILE="$WORK_DIR/conf_edits"
printf '%s' "$CONF_EDITS" > "$CONF_EDITS_FILE"
cat > "$REMOTE_SH" <<'REMOTE_EOF'
#!/bin/bash
# 由 deploy_be.sh 上传并在目标机器上执行
set -uo pipefail

: "${SR_HOME:?SR_HOME 未传入}" "${STAGE:?STAGE 未传入}" "${TS:?TS 未传入}" \
  "${ROLE:?ROLE 未传入}"
MODE="${MODE:-deploy}"     # deploy: 换 bin/lib；config: 改配置文件
CONF_DRY_RUN="${CONF_DRY_RUN:-0}"
NEW="$STAGE"          # scp 上传的新版本 bin/ lib/ 就在这里
BACKUP_DIR="$SR_HOME/deploy_backup/$TS"
START_SH="bin/start_$ROLE.sh"
STOP_SH="bin/stop_$ROLE.sh"
CONF_FILE="conf/$ROLE.conf"
OUT_FILE="log/$ROLE.out"
CONF_EDITS_FILE="$STAGE/conf_edits"
NEW_CONF="$STAGE/new.conf"
CONF_BAK="$SR_HOME/$CONF_FILE.bak.$TS"

log() {
    echo "  [$(hostname -s) $(date '+%H:%M:%S')] $*"
}

die() {
    log "错误: $*"
    exit 1
}

# 属于本 SR_HOME 的 starrocks_be 进程号。BE 和 CN 是同一个二进制，靠
# /proc/<pid>/exe、cwd 是否在本目录下区分，同机多实例/多角色都不误伤。
be_pids() {
    local pids="" p exe cwd
    for p in $(pgrep -x starrocks_be 2>/dev/null); do
        exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
        cwd="$(readlink "/proc/$p/cwd" 2>/dev/null)"
        if [ -z "$exe" ] && [ -z "$cwd" ]; then
            # 读不到 /proc 信息（权限不足等），保守地当成本实例
            pids="$pids $p"
        elif [ "${exe#$SR_HOME/}" != "$exe" ] \
            || [ "$cwd" = "$SR_HOME" ] || [ "${cwd#$SR_HOME/}" != "$cwd" ]; then
            # 比较时带上斜杠，避免 /data/sr/be 误判 /data/sr/be2 的实例
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

# http 端口：auto 时从 be.conf / cn.conf 读取（两者都叫 be_http_port），
# 读不到用 8040
resolve_http_port() {
    local port="$HEALTH_PORT"
    if [ "$port" = "auto" ]; then
        port="$(grep -E '^[[:space:]]*be_http_port[[:space:]]*=' "$SR_HOME/$CONF_FILE" 2>/dev/null \
                | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
        [ -n "$port" ] || port=8040
    fi
    echo "$port"
}

dump_be_out() {
    local out="$SR_HOME/$OUT_FILE"
    [ -f "$out" ] || return 0
    log "----- $out 最后 30 行 -----"
    tail -n 30 "$out" | sed 's/^/  | /'
    log "----------------------------"
}

start_be() {
    log "启动: ./$START_SH --daemon"
    ( cd "$SR_HOME" && "./$START_SH" --daemon )
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

# 按 conf_edits 生成新配置：set 替换第一处生效的 key（其余同名行注释掉），
# 没有则追加到末尾；unset 注释掉所有同名行。注释行不动。
apply_conf_edits() {
    awk -v ts="$TS" '
    FNR == NR {
        i = index($0, "\t"); op = substr($0, 1, i - 1); rest = substr($0, i + 1)
        j = index(rest, "\t")
        if (j) { k = substr(rest, 1, j - 1); v = substr(rest, j + 1) } else { k = rest; v = "" }
        if (!(k in kop)) order[++n] = k
        kop[k] = op; kval[k] = v
        next
    }
    {
        if (match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_.]*[ \t]*=/)) {
            k = substr($0, RSTART, RLENGTH - 1); gsub(/[ \t]/, "", k)
            if (k in kop) {
                if (kop[k] == "set" && !(k in done)) { print k " = " kval[k]; done[k] = 1; next }
                print "# " $0 "    # commented out by deploy " ts
                next
            }
        }
        print
    }
    END {
        for (i = 1; i <= n; i++) {
            k = order[i]
            if (kop[k] == "set" && !(k in done)) print k " = " kval[k]
        }
    }
    ' "$CONF_EDITS_FILE" "$SR_HOME/$CONF_FILE" > "$NEW_CONF"
}

# 改配置失败：恢复原配置并重新拉起
conf_rollback() {
    log "开始回滚配置: $CONF_BAK -> $CONF_FILE"
    [ -f "$CONF_BAK" ] || { log "配置备份不存在，无法回滚，请人工处理"; return 1; }
    ( cd "$SR_HOME" && "./$STOP_SH" >/dev/null 2>&1 )
    if ! wait_exit 60; then
        log "回滚前进程未退出，kill -9 $(be_pids)"
        kill -9 $(be_pids) 2>/dev/null
        sleep 5
    fi
    cp "$CONF_BAK" "$SR_HOME/$CONF_FILE" || { log "恢复配置失败"; return 1; }
    start_be
    if verify_be; then
        log "回滚完成，已恢复原配置"
    else
        log "回滚后启动仍失败，请人工处理"
        return 1
    fi
    return 0
}

# 回滚：丢弃新版本，恢复备份目录里的 bin/lib，并重新拉起
rollback() {
    if [ "$MODE" = config ]; then
        conf_rollback
        return
    fi
    log "开始回滚到备份: $BACKUP_DIR"
    if [ ! -d "$BACKUP_DIR/bin" ] || [ ! -d "$BACKUP_DIR/lib" ]; then
        log "备份不完整，无法回滚，请人工处理: $BACKUP_DIR"
        return 1
    fi
    ( cd "$SR_HOME" && "./$STOP_SH" >/dev/null 2>&1 )
    if ! wait_exit 60; then
        log "回滚前进程未退出，kill -9 $(be_pids)"
        kill -9 $(be_pids) 2>/dev/null
        sleep 5
    fi
    rm -rf "$SR_HOME/bin" "$SR_HOME/lib"
    mv "$BACKUP_DIR/bin" "$SR_HOME/bin" || { log "恢复 bin 失败"; return 1; }
    mv "$BACKUP_DIR/lib" "$SR_HOME/lib" || { log "恢复 lib 失败"; return 1; }
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
    elif [ "$MODE" = config ]; then
        log "ROLLBACK=0，未回滚。原配置在 $CONF_BAK"
    else
        log "ROLLBACK=0，未回滚。备份在 $BACKUP_DIR"
    fi
    exit 1
}

# ---- 1. 前置检查（此时还没停服务）----
[ -d "$SR_HOME" ] || die "远端目录不存在: $SR_HOME"
[ -x "$SR_HOME/$STOP_SH" ] || die "缺少可执行文件: $SR_HOME/${STOP_SH}（角色是不是选错了?）"
[ -x "$SR_HOME/$START_SH" ] || die "缺少可执行文件: $SR_HOME/${START_SH}（角色是不是选错了?）"
[ -d "$SR_HOME/lib" ] || die "缺少目录: $SR_HOME/lib"

if [ "$MODE" = config ]; then
    [ -f "$SR_HOME/$CONF_FILE" ] || die "配置文件不存在: $SR_HOME/$CONF_FILE"
    [ -f "$CONF_EDITS_FILE" ] || die "缺少配置修改列表: $CONF_EDITS_FILE"
    apply_conf_edits || die "生成新配置失败"
    if cmp -s "$SR_HOME/$CONF_FILE" "$NEW_CONF"; then
        log "配置无变化，跳过重启"
        exit 0
    fi
    log "配置 diff ($CONF_FILE):"
    diff -u "$SR_HOME/$CONF_FILE" "$NEW_CONF" | tail -n +3 | sed 's/^/  | /'
    if [ "$CONF_DRY_RUN" = 1 ]; then
        log "dry-run，未修改"
        exit 0
    fi
else
    [ -d "$NEW/bin" ] || die "上传的 bin 目录不存在: $NEW/bin"
    [ -d "$NEW/lib" ] || die "上传的 lib 目录不存在: $NEW/lib"
    [ -f "$NEW/$START_SH" ] || die "上传内容缺少 $START_SH"
    [ -f "$NEW/lib/starrocks_be" ] || die "上传内容缺少 lib/starrocks_be"
    chmod +x "$NEW"/bin/*.sh "$NEW/lib/starrocks_be" 2>/dev/null
    log "待部署的 bin/ lib/ 已就绪于 $NEW"
fi

# ---- 2. 停止服务并确认进程退出 ----
PIDS_BEFORE="$(be_pids)"
if [ -z "$PIDS_BEFORE" ]; then
    log "starrocks_be($ROLE) 当前未运行，仍执行一次 $STOP_SH"
else
    log "当前 starrocks_be($ROLE) pid=$PIDS_BEFORE"
fi
( cd "$SR_HOME" && "./$STOP_SH" ) || log "$STOP_SH 返回非 0，继续等待进程退出"

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

if [ "$MODE" = config ]; then
    # ---- 3/4. 备份并写入配置 ----
    # cp -p 保留原文件属性；写回用 cat 覆盖内容，不改变原文件的属主和权限
    cp -p "$SR_HOME/$CONF_FILE" "$CONF_BAK" || die "备份配置失败: $CONF_BAK"
    if ! cat "$NEW_CONF" > "$SR_HOME/$CONF_FILE"; then
        fail_after_backup "写入新配置失败"
    fi
    log "已写入新配置，原配置备份为 $CONF_BAK"
else
# ---- 3. 备份旧的 bin / lib ----
mkdir -p "$BACKUP_DIR" || die "无法创建备份目录: $BACKUP_DIR"
if [ -e "$BACKUP_DIR/bin" ] || [ -e "$BACKUP_DIR/lib" ]; then
    die "备份目录已有内容，可能是同一时间戳重复部署: $BACKUP_DIR"
fi
mv "$SR_HOME/bin" "$BACKUP_DIR/bin" || die "备份 bin 失败"
if ! mv "$SR_HOME/lib" "$BACKUP_DIR/lib"; then
    mv "$BACKUP_DIR/bin" "$SR_HOME/bin"
    die "备份 lib 失败，已把 bin 放回原位"
fi
log "已备份旧 bin/lib 到 $BACKUP_DIR"

# ---- 4. 覆盖为新版本 ----
if ! mv "$NEW/bin" "$SR_HOME/bin"; then
    rm -rf "$SR_HOME/bin"
    mv "$BACKUP_DIR/bin" "$SR_HOME/bin"
    mv "$BACKUP_DIR/lib" "$SR_HOME/lib"
    die "写入新 bin 失败，已恢复旧版本"
fi
if ! mv "$NEW/lib" "$SR_HOME/lib"; then
    fail_after_backup "写入新 lib 失败"
fi
log "新 bin/lib 已就位"
fi

# ---- 5. 启动 ----
if ! start_be; then
    fail_after_backup "$START_SH 返回非 0"
fi

# ---- 6. 确认启动正常 ----
if ! verify_be; then
    fail_after_backup "启动校验未通过"
fi

# ---- 7. 清理旧备份 ----
if [ "$BACKUP_KEEP" -gt 0 ] && [ "$MODE" = config ]; then
    old="$(ls -1dt "$SR_HOME/$CONF_FILE".bak.* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)))"
    if [ -n "$old" ]; then
        echo "$old" | while read -r f; do
            log "清理旧配置备份: $f"
            rm -f "$f"
        done
    fi
elif [ "$BACKUP_KEEP" -gt 0 ]; then
    old="$(ls -1dt "$SR_HOME/deploy_backup"/*/ 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)))"
    if [ -n "$old" ]; then
        echo "$old" | while read -r d; do
            log "清理旧备份: $d"
            rm -rf "$d"
        done
    fi
fi

log "部署成功"
REMOTE_EOF

# 把某份备份的 bin/ lib/ 复制到中转目录，输出实际选中的时间戳；
# 用法: bash -s -- <部署目录> <时间戳|last> <中转目录>
COPY_BACKUP_SH='
dir="$1/deploy_backup"; want="$2"; stage="$3"
if [ "$want" = last ]; then
    want="$(ls -1 "$dir" 2>/dev/null | grep -E "^[0-9]{8}_[0-9]{6}\$" | sort | tail -1)"
fi
if [ -z "$want" ] || [ ! -d "$dir/$want/bin" ] || [ ! -d "$dir/$want/lib" ]; then
    echo "备份不存在或不完整: $dir/${want:-<无备份>}" >&2
    exit 1
fi
cp -a "$dir/$want/bin" "$dir/$want/lib" "$stage/" || exit 1
echo "$want"
'

# 在单台机器上跑完整流程，返回非 0 表示该机器失败
deploy_one() {
    local host="$1"
    local target="$SSH_TARGET_PREFIX$host"

    if ! $SSH_CMD "$target" "mkdir -p '$STAGE'"; then
        log "$host: 无法连接或创建中转目录 $STAGE"
        return 1
    fi

    if [ "$MODE" = config ]; then
        if ! $SCP_CMD "$REMOTE_SH" "$CONF_EDITS_FILE" "$target:$STAGE/"; then
            log "$host: 上传失败"
            $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
            return 1
        fi
    elif [ -n "$RESTORE_TS" ]; then
        # 复制而不是移动：切换失败回滚时备份仍然完好
        local picked
        log "$host: 复制备份 $RESTORE_TS 的 bin/ lib/ -> $STAGE/"
        if ! picked="$($SSH_CMD "$target" bash -s -- "'$REMOTE_BE'" "'$RESTORE_TS'" "'$STAGE'" <<< "$COPY_BACKUP_SH")" \
            || ! $SCP_CMD "$REMOTE_SH" "$target:$STAGE/"; then
            log "$host: 准备备份失败"
            $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
            return 1
        fi
        log "$host: 已准备好备份 $picked"
    else
        log "$host: scp bin/ lib/ -> $STAGE/ ($COPY_SIZE)"
        if ! $SCP_CMD -r "$LOCAL_BE/bin" "$LOCAL_BE/lib" "$REMOTE_SH" "$target:$STAGE/"; then
            log "$host: 上传失败"
            $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
            return 1
        fi
        log "$host: 上传完成"
    fi

    local rc=0
    $SSH_CMD "$target" \
        "SR_HOME='$REMOTE_BE' STAGE='$STAGE' TS='$TS' ROLE='$ROLE' \
         MODE='$MODE' CONF_DRY_RUN='$DRY_RUN' \
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