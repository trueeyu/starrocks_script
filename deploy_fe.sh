#!/bin/bash

# ============================================================
# deploy_fe.sh - 把本地编译出的 FE（bin、lib 等）部署到远端 FE 节点
#
# 部署的目录：bin/ lib/ 必须有；webroot/ spark-dpp/ hive-udf/ 本地有就一起部署。
# conf/ meta/ log/ 从不改动。
#
# 单台机器的部署流程（在远端执行）：
#   1. scp 上述目录到远端中转目录（上传失败则不停服务）
#      默认放在部署目录的上级目录，和部署目录同一文件系统，mv 是瞬间改名
#   2. ./bin/stop_fe.sh，等待 StarRocksFE 进程真正退出
#   3. 把旧目录移动到备份目录
#   4. 用新目录覆盖
#   5. ./bin/start_fe.sh --daemon
#   6. 确认进程存活 + HTTP /api/bootstrap 返回 OK（元数据回放完成、可以服务）
#   7. 任一步失败（且 ROLLBACK=1）自动回滚到备份版本并重新拉起
#
# 多台机器按给出的顺序串行滚动部署，一台就绪后才动下一台，默认某台失败即停止。
# 升级版本时 Leader 要放在最后（先 Observer，再 Follower，最后 Leader），
# 否则新版 Leader 写出的元数据日志，旧版 Follower 可能无法回放。
#
# 切换到历史版本：-l 列出每台机器上的备份，-R <时间戳|last> 切换到某份备份。
# 切换时备份先在远端复制到中转目录（不上传），之后流程同上，当前版本也会
# 存成一份新备份，因此可以再切回来。meta/ 不在备份里：新版本改写过的元数据，
# 旧版本不一定能读。
#
# 修改配置并重启：-C key=value / -U key（可重复），-S 查看配置。各机器上先算出
# 新的 conf/fe.conf 并打印 diff，无变化的机器跳过；有变化则停服、备份为
# conf/fe.conf.bak.<ts>、写入、启动、检查，失败自动恢复原配置。
# ============================================================

set -uo pipefail

# ---- 配置项（均可用环境变量覆盖）----
LOCAL_FE="${LOCAL_FE:-./fe}"        # 本地目录（需包含 bin/ 和 lib/）
REMOTE_FE="${REMOTE_FE:-}"          # 远端部署目录，必填（或用 -d 指定）
STAGE_DIR="${STAGE_DIR:-}"          # 远端中转目录的父目录，留空=部署目录的上级目录（或用 -t 指定）
HOSTS="${HOSTS:-}"                  # 目标机器，逗号或空格分隔（或用 -H / -f / 位置参数）
SSH_USER="${SSH_USER:-}"            # ssh 用户名，留空表示用当前用户/ssh config
SSH_PORT="${SSH_PORT:-}"            # ssh 端口，留空表示默认
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=10}"
SCP_COMPRESS="${SCP_COMPRESS:-1}"   # scp 传输压缩（-C），0 关闭

STOP_TIMEOUT="${STOP_TIMEOUT:-120}"   # 等待 StarRocksFE 退出的最长时间（秒）
START_TIMEOUT="${START_TIMEOUT:-600}" # 等待启动就绪的最长时间（秒），元数据大时回放较慢
STABLE_WAIT="${STABLE_WAIT:-10}"      # 进程起来后再观察多久，防止起来就崩
FORCE_KILL="${FORCE_KILL:-0}"         # 停止超时后是否 kill -9
ROLLBACK="${ROLLBACK:-1}"             # 部署失败是否自动回滚
HEALTH_PORT="${HEALTH_PORT:-auto}"    # http 端口；auto=从 fe.conf 读取，0=跳过就绪检查
BACKUP_KEEP="${BACKUP_KEEP:-5}"       # 远端保留的备份份数
REMOTE_JAVA_HOME="${REMOTE_JAVA_HOME:-}" # 远端 JAVA_HOME，留空=沿用正在运行的 FE 的 JAVA_HOME

CONTINUE_ON_ERROR=0
ASSUME_YES=0
DRY_RUN=0
LIST_BACKUPS=0
RESTORE_TS=""
CONF_EDITS=""          # 每行一条: set<TAB>key<TAB>value 或 unset<TAB>key
SHOW_KEYS=""           # -S: 逗号分隔的配置项，或 all

# 必须部署的目录 + 本地存在才部署的目录
REQUIRED_DIRS="bin lib"
OPTIONAL_DIRS="webroot spark-dpp hive-udf"

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
用法: ./deploy_fe.sh [选项] [host ...]

选项:
  -s <dir>    本地目录，需包含 bin/ 和 lib/             (默认 ./fe，或 LOCAL_FE)
  -d <dir>    远端部署目录（必填，或 REMOTE_FE）
  -t <dir>    远端中转目录的父目录，上传内容先放在 <dir>/.fe_deploy_<ts>/
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
              (不需要 -s；当前版本会另存一份备份，可以再切回来；meta/ 不会回退)
  -C <k=v>    修改 conf/fe.conf 中的配置项并重启，可重复（不需要 -s）
  -U <key>    注释掉 conf/fe.conf 中的配置项（恢复默认值）并重启，可重复
              (-C/-U 加 -n 时只打印各机器上的配置 diff，不做修改)
  -S <keys>   查看各机器 conf/fe.conf 中的配置项，逗号分隔；all 表示全部生效行
              (只读配置文件；运行中的值可能已被 ADMIN SET FRONTEND CONFIG 临时改过)
  -h          显示帮助

按给出的顺序逐台部署。升级版本时把 Leader 放在最后。

环境变量: STOP_TIMEOUT START_TIMEOUT STABLE_WAIT ROLLBACK HEALTH_PORT
          BACKUP_KEEP REMOTE_JAVA_HOME SSH_OPTS SCP_COMPRESS

示例:
  ./deploy_fe.sh -s ~/starrocks/output/fe -d /home/disk1/sr/fe -f fe_hosts.txt -u sr
  ./deploy_fe.sh -s ~/starrocks/output/fe -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -n   # 只看计划
  ./deploy_fe.sh -s ~/starrocks/output/fe -d /home/disk1/sr/fe -u sr fe02 fe03 fe01      # fe01 是 Leader
  ./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -l                  # 列出备份
  ./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -R 20260927_082927  # 切到该备份
  ./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -R last             # 切到最近一份备份
  ./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -S JAVA_OPTS,sys_log_level  # 查看配置
  ./deploy_fe.sh -d /home/disk1/sr/fe -f fe_hosts.txt -u sr -C sys_log_level=WARN -n    # 预览配置 diff
  ./deploy_fe.sh -d /home/disk1/sr/fe -u sr -C sys_log_level=WARN fe02 fe03 fe01
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
while getopts ":s:d:t:H:f:u:p:ykcnlR:C:U:S:h" opt; do
    case "$opt" in
        s) LOCAL_FE="$OPTARG" ;;
        d) REMOTE_FE="$OPTARG" ;;
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
        -*) die "选项 $h 必须写在主机名之前，例如: ./deploy_fe.sh -d /data/fe -c fe01 fe02" ;;
    esac
done
[ -n "$REMOTE_FE" ] || { usage; die "未指定远端部署目录（-d 或 REMOTE_FE）"; }
case "$REMOTE_FE" in
    /*) ;;
    *) die "远端部署目录必须是绝对路径: $REMOTE_FE" ;;
esac
# 去掉末尾的 /，否则 dirname /a/b/ 之类的结果不符合预期
while [ "${REMOTE_FE%/}" != "$REMOTE_FE" ] && [ "$REMOTE_FE" != / ]; do
    REMOTE_FE="${REMOTE_FE%/}"
done
[ "$REMOTE_FE" != / ] || die "远端部署目录不能是 /"

[ -n "$STAGE_DIR" ] || STAGE_DIR="$(dirname "$REMOTE_FE")"
case "$STAGE_DIR" in
    /*) ;;
    *) die "中转目录必须是绝对路径: $STAGE_DIR" ;;
esac
STAGE_DIR="${STAGE_DIR%/}"

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

if [ "$MODE" = config ] || [ -n "$SHOW_KEYS" ]; then
    DEPLOY_DIRS="$REQUIRED_DIRS"    # 不换目录，只是远端脚本要求有值
elif [ -n "$RESTORE_TS" ] || [ "$LIST_BACKUPS" = 1 ]; then
    # 切换时处理全部目录：备份里没有的可选目录，说明旧版本没有它，会被移走
    DEPLOY_DIRS="$REQUIRED_DIRS $OPTIONAL_DIRS"
else
    # ---- 检查本地目录 ----
    [ -d "$LOCAL_FE" ] || die "本地目录不存在: $LOCAL_FE"
    for d in $REQUIRED_DIRS; do
        [ -d "$LOCAL_FE/$d" ] || die "本地缺少目录: $LOCAL_FE/$d"
    done
    [ -f "$LOCAL_FE/bin/start_fe.sh" ] || die "本地缺少文件: $LOCAL_FE/bin/start_fe.sh"
    [ -f "$LOCAL_FE/bin/stop_fe.sh" ] || die "本地缺少文件: $LOCAL_FE/bin/stop_fe.sh"
    [ -f "$LOCAL_FE/lib/starrocks-fe.jar" ] || die "本地缺少文件: $LOCAL_FE/lib/starrocks-fe.jar"

    DEPLOY_DIRS="$REQUIRED_DIRS"
    for d in $OPTIONAL_DIRS; do
        [ -d "$LOCAL_FE/$d" ] && DEPLOY_DIRS="$DEPLOY_DIRS $d"
    done
fi

TS="$(date '+%Y%m%d_%H%M%S')"
STAGE="$STAGE_DIR/.fe_deploy_$TS"

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
    log "远端目录 : $REMOTE_FE/deploy_backup/"
    log "时间戳是备份生成（即被替换下来）的时间，里面是那次部署之前的版本"
    rc=0
    for host in "${HOST_LIST[@]}"; do
        echo "  $host:"
        $SSH_CMD "$SSH_TARGET_PREFIX$host" bash -s -- "'$REMOTE_FE'" <<< "$LIST_BACKUPS_SH" \
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
    log "配置文件 : $REMOTE_FE/conf/fe.conf"
    rc=0
    for host in "${HOST_LIST[@]}"; do
        echo "  $host:"
        $SSH_CMD "$SSH_TARGET_PREFIX$host" bash -s -- "'$REMOTE_FE/conf/fe.conf'" "'$SHOW_KEYS'" \
            <<< "$SHOW_CONF_SH" || { echo "    (失败)"; rc=1; }
    done
    exit $rc
fi

LOCAL_PATHS=()
if [ "$MODE" = deploy ] && [ -z "$RESTORE_TS" ]; then
    for d in $DEPLOY_DIRS; do
        LOCAL_PATHS+=("$LOCAL_FE/$d")
    done
    COPY_SIZE="$(du -shc "${LOCAL_PATHS[@]}" 2>/dev/null | tail -1 | awk '{print $1}')"
fi

# ---- 部署计划 ----
if [ "$MODE" = config ]; then
    log "修改配置 : $REMOTE_FE/conf/fe.conf  (原文件备份为 fe.conf.bak.${TS}，保留最近 $BACKUP_KEEP 份)"
    printf '%s' "$CONF_EDITS" | while IFS=$'\t' read -r op key value; do
        if [ "$op" = set ]; then
            log "           $key = $value"
        else
            log "           $key  (注释掉，恢复默认值)"
        fi
    done
elif [ "$RESTORE_TS" = last ]; then
    log "切换到   : 各机器 $REMOTE_FE/deploy_backup/ 下最近的一份备份  (先在远端复制到中转目录，不上传)"
elif [ -n "$RESTORE_TS" ]; then
    log "切换到   : 远端备份 $REMOTE_FE/deploy_backup/$RESTORE_TS  (先在远端复制到中转目录，不上传)"
else
    log "本地目录 : $(cd "$LOCAL_FE" && pwd)  ($DEPLOY_DIRS 共 $COPY_SIZE)"
fi
log "远端目录 : $REMOTE_FE"
log "中转目录 : $STAGE  (部署结束后删除)"
log "目标机器 : ${HOST_LIST[*]}  (按此顺序，Leader 应在最后)"
[ "$MODE" = deploy ] && log "备份目录 : $REMOTE_FE/deploy_backup/$TS (保留最近 $BACKUP_KEEP 份)"
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
    printf '将按顺序重启以上 %d 台机器的 FE%s（Leader 应在最后），确认继续? [y/N] ' \
        "${#HOST_LIST[@]}" "$what"
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
# 由 deploy_fe.sh 上传并在目标机器上执行
set -uo pipefail

: "${SR_HOME:?SR_HOME 未传入}" "${STAGE:?STAGE 未传入}" "${TS:?TS 未传入}" \
  "${DEPLOY_DIRS:?DEPLOY_DIRS 未传入}"
MODE="${MODE:-deploy}"     # deploy: 换目录；config: 改配置文件
CONF_DRY_RUN="${CONF_DRY_RUN:-0}"
NEW="$STAGE"          # scp 上传的新版本目录就在这里
BACKUP_DIR="$SR_HOME/deploy_backup/$TS"
START_SH="bin/start_fe.sh"
STOP_SH="bin/stop_fe.sh"
CONF_FILE="conf/fe.conf"
OUT_FILE="log/fe.out"
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

# 进程的某个环境变量，读不到输出空
proc_env() {
    [ -r "/proc/$1/environ" ] || return 0
    tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" | sed -n "s/^$2=//p" | head -1
}

# 属于本 SR_HOME 的 StarRocksFE 进程号。java 是共用的，靠 start_fe.sh
# export 的 STARROCKS_HOME 区分，同机多实例不误伤。
fe_pids() {
    local pids="" p home pidfile_pid
    pidfile_pid="$(cat "$SR_HOME/bin/fe.pid" 2>/dev/null)"
    for p in $(pgrep -f 'com\.starrocks\.StarRocksFE' 2>/dev/null); do
        home="$(proc_env "$p" STARROCKS_HOME)"
        if [ -z "$home" ]; then
            # 读不到 environ（别的用户的进程等），只认本目录 bin/fe.pid 里记录的那个
            [ "$p" = "$pidfile_pid" ] && pids="$pids $p"
        elif [ "${home%/}" = "$SR_HOME" ]; then
            pids="$pids $p"
        fi
    done
    echo "${pids# }"
}

wait_exit() {
    local timeout="$1" waited=0
    while [ -n "$(fe_pids)" ]; do
        [ "$waited" -ge "$timeout" ] && return 1
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

# http 端口：auto 时从 fe.conf 读取 http_port，读不到用 8030
resolve_http_port() {
    local port="$HEALTH_PORT"
    if [ "$port" = "auto" ]; then
        port="$(grep -E '^[[:space:]]*http_port[[:space:]]*=' "$SR_HOME/$CONF_FILE" 2>/dev/null \
                | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
        [ -n "$port" ] || port=8030
    fi
    echo "$port"
}

dump_fe_out() {
    local f
    for f in "$SR_HOME/$OUT_FILE" "$SR_HOME/log/fe.log"; do
        [ -f "$f" ] || continue
        log "----- $f 最后 30 行 -----"
        tail -n 30 "$f" | sed 's/^/  | /'
        log "----------------------------"
    done
}

# stop_fe.sh 默认会无限等待进程退出，放到后台跑，超时由 wait_exit 控制
stop_fe() {
    local timeout="$1" spid rc=0 i=0
    ( cd "$SR_HOME" && exec "./$STOP_SH" ) &
    spid=$!
    wait_exit "$timeout" || rc=1
    # 必须等 stop_fe.sh 自己结束再往下走：否则它可能晚一步读到新 FE 写的
    # bin/fe.pid，把刚拉起的新进程杀掉。FE 已退出时它很快就会结束。
    while kill -0 "$spid" 2>/dev/null && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$spid" 2>/dev/null; then
        pkill -P "$spid" 2>/dev/null
        kill "$spid" 2>/dev/null
    fi
    wait "$spid" 2>/dev/null
    return $rc
}

start_fe() {
    log "启动: ./$START_SH --daemon"
    ( cd "$SR_HOME" && "./$START_SH" --daemon )
}

# 等进程起来 -> 观察 STABLE_WAIT -> /api/bootstrap 返回 OK
verify_fe() {
    local waited=0 pids port body
    while :; do
        pids="$(fe_pids)"
        [ -n "$pids" ] && break
        if [ "$waited" -ge "$START_TIMEOUT" ]; then
            log "StarRocksFE 进程未出现（等待 ${waited}s）"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "StarRocksFE 已启动, pid=$pids"

    if [ "$STABLE_WAIT" -gt 0 ]; then
        sleep "$STABLE_WAIT"
        waited=$((waited + STABLE_WAIT))
        pids="$(fe_pids)"
        if [ -z "$pids" ]; then
            log "StarRocksFE 启动后 ${STABLE_WAIT}s 内退出"
            return 1
        fi
        log "观察 ${STABLE_WAIT}s 后进程仍存活, pid=$pids"
    fi

    port="$(resolve_http_port)"
    if [ "$port" = "0" ]; then
        log "已跳过就绪检查"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log "警告: 未安装 curl，跳过就绪检查"
        return 0
    fi

    # /api/bootstrap 不需要认证，元数据回放完成、FE 可以服务后才返回 "status":"OK"
    log "等待 FE 就绪: http://127.0.0.1:$port/api/bootstrap"
    while :; do
        body="$(curl -s -m 3 "http://127.0.0.1:$port/api/bootstrap" 2>/dev/null)"
        if echo "$body" | grep -q '"status" *: *"OK"'; then
            log "FE 已就绪（启动耗时约 ${waited}s）"
            return 0
        fi
        if [ -z "$(fe_pids)" ]; then
            log "等待就绪期间进程已退出"
            return 1
        fi
        if [ "$waited" -ge "$START_TIMEOUT" ]; then
            log "等待就绪超时（${waited}s），最后返回: ${body:-无响应}"
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
    if ! stop_fe 60; then
        log "回滚前进程未退出，kill -9 $(fe_pids)"
        kill -9 $(fe_pids) 2>/dev/null
        sleep 5
    fi
    cp "$CONF_BAK" "$SR_HOME/$CONF_FILE" || { log "恢复配置失败"; return 1; }
    start_fe
    if verify_fe; then
        log "回滚完成，已恢复原配置"
    else
        log "回滚后启动仍失败，请人工处理"
        return 1
    fi
    return 0
}

# 回滚：丢弃新版本，恢复备份目录里的旧目录，并重新拉起
rollback() {
    local d
    if [ "$MODE" = config ]; then
        conf_rollback
        return
    fi
    log "开始回滚到备份: $BACKUP_DIR"
    if [ ! -d "$BACKUP_DIR/bin" ] || [ ! -d "$BACKUP_DIR/lib" ]; then
        log "备份不完整，无法回滚，请人工处理: $BACKUP_DIR"
        return 1
    fi
    if ! stop_fe 60; then
        log "回滚前进程未退出，kill -9 $(fe_pids)"
        kill -9 $(fe_pids) 2>/dev/null
        sleep 5
    fi
    for d in $DEPLOY_DIRS; do
        rm -rf "${SR_HOME:?}/$d"
        if [ -e "$BACKUP_DIR/$d" ]; then
            mv "$BACKUP_DIR/$d" "$SR_HOME/$d" || { log "恢复 $d 失败"; return 1; }
        fi
    done
    rmdir "$BACKUP_DIR" 2>/dev/null
    start_fe
    if verify_fe; then
        log "回滚完成，已恢复到旧版本"
    else
        log "回滚后启动仍失败，请人工处理"
        return 1
    fi
    return 0
}

fail_after_backup() {
    log "部署失败: $1"
    dump_fe_out
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
[ -x "$SR_HOME/$STOP_SH" ] || die "缺少可执行文件: $SR_HOME/$STOP_SH"
[ -x "$SR_HOME/$START_SH" ] || die "缺少可执行文件: $SR_HOME/$START_SH"
[ -f "$SR_HOME/$CONF_FILE" ] || die "缺少配置文件: $SR_HOME/${CONF_FILE}（目录是不是选错了?）"
[ -d "$SR_HOME/lib" ] || die "缺少目录: $SR_HOME/lib"

if [ "$MODE" = config ]; then
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
    for d in bin lib; do
        [ -d "$NEW/$d" ] || die "上传的 $d 目录不存在: $NEW/$d"
    done
    [ -f "$NEW/$START_SH" ] || die "上传内容缺少 $START_SH"
    [ -f "$NEW/lib/starrocks-fe.jar" ] || die "上传内容缺少 lib/starrocks-fe.jar"
    chmod +x "$NEW"/bin/*.sh 2>/dev/null
    log "待部署的 $DEPLOY_DIRS 已就绪于 $NEW"
fi

PIDS_BEFORE="$(fe_pids)"

# ssh 非登录 shell 里常常没有 JAVA_HOME / java，而 start_fe.sh 需要它们。
# 依次用：传入的 REMOTE_JAVA_HOME、当前环境、正在运行的 FE 的 JAVA_HOME；
# fe.conf 里配置了 JAVA_HOME 时 start_fe.sh 会自己读取。
if [ -n "$REMOTE_JAVA_HOME" ]; then
    export JAVA_HOME="$REMOTE_JAVA_HOME"
elif [ -z "${JAVA_HOME:-}" ]; then
    for p in $PIDS_BEFORE; do
        jh="$(proc_env "$p" JAVA_HOME)"
        if [ -n "$jh" ]; then
            export JAVA_HOME="$jh"
            log "沿用运行中 FE 的 JAVA_HOME=$JAVA_HOME"
            break
        fi
    done
fi
if [ -n "${JAVA_HOME:-}" ]; then
    [ -x "$JAVA_HOME/bin/java" ] || die "JAVA_HOME 下没有可执行的 java: $JAVA_HOME"
elif ! grep -qE '^[[:space:]]*JAVA_HOME[[:space:]]*=' "$SR_HOME/$CONF_FILE" \
        && ! command -v java >/dev/null 2>&1; then
    die "找不到 java：未设置 JAVA_HOME、fe.conf 未配置、PATH 里也没有；可用 REMOTE_JAVA_HOME 指定"
fi

# ---- 2. 停止服务并确认进程退出 ----
if [ -z "$PIDS_BEFORE" ]; then
    log "StarRocksFE 当前未运行，仍执行一次 $STOP_SH"
else
    log "当前 StarRocksFE pid=$PIDS_BEFORE"
fi

if ! stop_fe "$STOP_TIMEOUT"; then
    if [ "$FORCE_KILL" = "1" ]; then
        log "等待 ${STOP_TIMEOUT}s 未退出，kill -9 $(fe_pids)"
        kill -9 $(fe_pids) 2>/dev/null
        wait_exit 30 || die "kill -9 后进程仍存在: $(fe_pids)"
    else
        die "等待 StarRocksFE 退出超时 (${STOP_TIMEOUT}s), pid=$(fe_pids)；可加 -k 强制 kill"
    fi
fi
log "StarRocksFE 已完全退出"

if [ "$MODE" = config ]; then
    # ---- 3/4. 备份并写入配置 ----
    # cp -p 保留原文件属性；写回用 cat 覆盖内容，不改变原文件的属主和权限
    cp -p "$SR_HOME/$CONF_FILE" "$CONF_BAK" || die "备份配置失败: $CONF_BAK"
    if ! cat "$NEW_CONF" > "$SR_HOME/$CONF_FILE"; then
        fail_after_backup "写入新配置失败"
    fi
    log "已写入新配置，原配置备份为 $CONF_BAK"
else
# ---- 3. 备份旧目录 ----
mkdir -p "$BACKUP_DIR" || die "无法创建备份目录: $BACKUP_DIR"
for d in $DEPLOY_DIRS; do
    [ -e "$BACKUP_DIR/$d" ] && die "备份目录已有内容，可能是同一时间戳重复部署: $BACKUP_DIR"
done
MOVED=""
for d in $DEPLOY_DIRS; do
    [ -e "$SR_HOME/$d" ] || continue
    if ! mv "$SR_HOME/$d" "$BACKUP_DIR/$d"; then
        for m in $MOVED; do
            mv "$BACKUP_DIR/$m" "$SR_HOME/$m"
        done
        die "备份 $d 失败，已把已移动的目录放回原位"
    fi
    MOVED="$MOVED $d"
done
log "已备份旧的${MOVED} 到 $BACKUP_DIR"

# ---- 4. 覆盖为新版本 ----
for d in $DEPLOY_DIRS; do
    if [ ! -d "$NEW/$d" ]; then
        # 只有切换到备份时会发生：要切换到的版本没有这个目录
        [ -e "$BACKUP_DIR/$d" ] && log "新版本没有 $d/，当前的已随旧版本移入备份"
        continue
    fi
    if ! mv "$NEW/$d" "$SR_HOME/$d"; then
        fail_after_backup "写入新 $d 失败"
    fi
done
log "新的 $DEPLOY_DIRS 已就位"
fi

# ---- 5. 启动 ----
if ! start_fe; then
    fail_after_backup "$START_SH 返回非 0"
fi

# ---- 6. 确认启动正常 ----
if ! verify_fe; then
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

# 把某份备份里的目录复制到中转目录，输出实际选中的时间戳；
# 用法: bash -s -- <部署目录> <时间戳|last> <中转目录> "<目录列表>"
COPY_BACKUP_SH='
dir="$1/deploy_backup"; want="$2"; stage="$3"; dirs="$4"
if [ "$want" = last ]; then
    want="$(ls -1 "$dir" 2>/dev/null | grep -E "^[0-9]{8}_[0-9]{6}\$" | sort | tail -1)"
fi
if [ -z "$want" ] || [ ! -d "$dir/$want/bin" ] || [ ! -d "$dir/$want/lib" ]; then
    echo "备份不存在或不完整: $dir/${want:-<无备份>}" >&2
    exit 1
fi
for d in $dirs; do
    [ -d "$dir/$want/$d" ] || continue
    cp -a "$dir/$want/$d" "$stage/" || exit 1
done
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
        log "$host: 复制备份 $RESTORE_TS -> $STAGE/"
        if ! picked="$($SSH_CMD "$target" bash -s -- "'$REMOTE_FE'" "'$RESTORE_TS'" "'$STAGE'" "'$DEPLOY_DIRS'" <<< "$COPY_BACKUP_SH")" \
            || ! $SCP_CMD "$REMOTE_SH" "$target:$STAGE/"; then
            log "$host: 准备备份失败"
            $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
            return 1
        fi
        log "$host: 已准备好备份 $picked"
    else
        log "$host: scp $DEPLOY_DIRS -> $STAGE/ ($COPY_SIZE)"
        if ! $SCP_CMD -r "${LOCAL_PATHS[@]}" "$REMOTE_SH" "$target:$STAGE/"; then
            log "$host: 上传失败"
            $SSH_CMD "$target" "rm -rf '$STAGE'" >/dev/null 2>&1
            return 1
        fi
        log "$host: 上传完成"
    fi

    local rc=0
    $SSH_CMD "$target" \
        "SR_HOME='$REMOTE_FE' STAGE='$STAGE' TS='$TS' DEPLOY_DIRS='$DEPLOY_DIRS' \
         MODE='$MODE' CONF_DRY_RUN='$DRY_RUN' \
         STOP_TIMEOUT='$STOP_TIMEOUT' START_TIMEOUT='$START_TIMEOUT' \
         STABLE_WAIT='$STABLE_WAIT' FORCE_KILL='$FORCE_KILL' \
         ROLLBACK='$ROLLBACK' HEALTH_PORT='$HEALTH_PORT' \
         BACKUP_KEEP='$BACKUP_KEEP' REMOTE_JAVA_HOME='$REMOTE_JAVA_HOME' \
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
