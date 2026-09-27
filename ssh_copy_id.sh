#!/bin/bash

# ============================================================
# ssh_copy_id.sh - 批量把本机公钥装到远端机器，配置免密 ssh
#
# 主机列表的写法和 deploy_be.sh 一致（-H / -f / 位置参数），
# 配好之后就可以直接用 deploy_be.sh 部署。
#
# 每台机器的流程：
#   1. 用 BatchMode 试连一次，已经免密的直接跳过（-F 强制重装）
#   2. ssh-copy-id 安装公钥（需要输入一次该机器的密码）
#   3. 再用 BatchMode 试连，确认免密生效
#
# 本地没有密钥时自动生成一把无口令的 ed25519 密钥。
# 用 -P 时只输入一次密码，借助 sshpass 用于所有机器。
# 某台失败不影响其余机器，最后汇总，有失败则返回非 0。
# ============================================================

set -uo pipefail

# ---- 配置项（均可用环境变量覆盖）----
HOSTS="${HOSTS:-}"                  # 目标机器，逗号或空格分隔（或用 -H / -f / 位置参数）
SSH_USER="${SSH_USER:-}"            # ssh 用户名，留空表示用当前用户/ssh config
SSH_PORT="${SSH_PORT:-}"            # ssh 端口，留空表示默认
SSH_KEY="${SSH_KEY:-}"              # 私钥路径，留空=已有的 id_ed25519 / id_rsa，都没有则生成 id_ed25519
# accept-new: 首次连接自动信任主机指纹，已记录的指纹变了仍然拒绝
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}"

ASK_PASS=0
FORCE=0
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
用法: ./ssh_copy_id.sh [选项] [host ...]

选项:
  -H <hosts>  目标机器，逗号/空格分隔（或 HOSTS，或位置参数）
  -f <file>   从文件读取机器列表，一行一个，# 开头为注释
  -u <user>   ssh 用户名                                (或 SSH_USER)
  -p <port>   ssh 端口                                  (或 SSH_PORT)
  -i <key>    私钥路径，公钥为 <key>.pub                (或 SSH_KEY)
  -P          只输入一次密码，用于所有机器（需要 sshpass；也可设 SSHPASS）
  -F          已经免密的机器也重新安装公钥
  -n          只检查哪些机器已经免密，不做修改
  -h          显示帮助

环境变量: SSH_OPTS SSHPASS

示例:
  ./ssh_copy_id.sh -f hosts.txt -u sr
  ./ssh_copy_id.sh -f hosts.txt -u sr -P        # 所有机器密码相同，只输一次
  ./ssh_copy_id.sh -f hosts.txt -u sr -n        # 只看哪些还没配好
  ./ssh_copy_id.sh -u sr -i ~/.ssh/id_sr be01 be02
EOF
}

# ---- 参数解析 ----
HOST_FILE=""
while getopts ":H:f:u:p:i:PFnh" opt; do
    case "$opt" in
        H) HOSTS="$OPTARG" ;;
        f) HOST_FILE="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        p) SSH_PORT="$OPTARG" ;;
        i) SSH_KEY="$OPTARG" ;;
        P) ASK_PASS=1 ;;
        F) FORCE=1 ;;
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
        -*) die "选项 $h 必须写在主机名之前，例如: ./ssh_copy_id.sh -u sr be01 be02" ;;
    esac
done

command -v ssh-copy-id >/dev/null 2>&1 || die "未找到 ssh-copy-id"

# ---- 密码 ----
if [ "$ASK_PASS" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    command -v sshpass >/dev/null 2>&1 \
        || die "-P 需要 sshpass（macOS: brew install hudochenkov/sshpass/sshpass；Linux: yum/apt install sshpass）"
    if [ -z "${SSHPASS:-}" ]; then
        printf 'ssh 密码%s: ' "${SSH_USER:+ ($SSH_USER)}"
        read -rs SSHPASS
        echo
        [ -n "$SSHPASS" ] || die "密码为空"
    fi
    export SSHPASS
fi

# ---- 确定密钥 ----
if [ -z "$SSH_KEY" ]; then
    for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        if [ -f "$k" ]; then
            SSH_KEY="$k"
            break
        fi
    done
    [ -n "$SSH_KEY" ] || SSH_KEY="$HOME/.ssh/id_ed25519"
fi

if [ ! -f "$SSH_KEY" ]; then
    [ "$DRY_RUN" = 1 ] && die "私钥不存在: ${SSH_KEY}（dry-run 不生成）"
    log "私钥不存在，生成无口令的 ed25519 密钥: $SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")" && chmod 700 "$(dirname "$SSH_KEY")"
    ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY" -C "$(whoami)@$(hostname)" \
        || die "生成密钥失败"
fi
[ -f "$SSH_KEY.pub" ] || die "公钥不存在: $SSH_KEY.pub"

SSH_TARGET_PREFIX=""
[ -n "$SSH_USER" ] && SSH_TARGET_PREFIX="$SSH_USER@"
# 故意不加引号展开，SSH_OPTS 里是多个选项
SSH_CMD="ssh $SSH_OPTS"
COPY_CMD="ssh-copy-id $SSH_OPTS -i $SSH_KEY.pub"
if [ -n "$SSH_PORT" ]; then
    SSH_CMD="$SSH_CMD -p $SSH_PORT"
    COPY_CMD="$COPY_CMD -p $SSH_PORT"
fi
[ "$ASK_PASS" = 1 ] && COPY_CMD="sshpass -e $COPY_CMD"

log "公钥     : $SSH_KEY.pub"
log "目标机器 : ${HOST_LIST[*]}"
[ -n "$SSH_USER" ] && log "ssh 用户 : $SSH_USER"

# 免密是否已生效：只用这把钥匙、不允许输密码
can_login() {
    $SSH_CMD -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_KEY" "$1" true </dev/null >/dev/null 2>&1
}

# ---- 逐台处理 ----
OK_HOSTS=""
SKIP_HOSTS=""
FAIL_HOSTS=""

for host in "${HOST_LIST[@]}"; do
    # 主机名里已经带了 user@ 就不再加前缀
    case "$host" in
        *@*) target="$host" ;;
        *) target="$SSH_TARGET_PREFIX$host" ;;
    esac

    if [ "$FORCE" != 1 ] && can_login "$target"; then
        log "$host: 已免密，跳过"
        SKIP_HOSTS="$SKIP_HOSTS $host"
        continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
        log "$host: 未免密"
        FAIL_HOSTS="$FAIL_HOSTS $host"
        continue
    fi

    log "$host: 安装公钥"
    if ! $COPY_CMD "$target"; then
        log "$host: ssh-copy-id 失败"
        FAIL_HOSTS="$FAIL_HOSTS $host"
        continue
    fi

    if can_login "$target"; then
        log "$host: 免密已生效"
        OK_HOSTS="$OK_HOSTS $host"
    else
        # 常见原因：远端 home 或 ~/.ssh 权限过宽，sshd 拒绝使用 authorized_keys
        log "$host: 公钥已安装但免密登录仍失败，检查远端 ~ 和 ~/.ssh 的权限"
        FAIL_HOSTS="$FAIL_HOSTS $host"
    fi
done

# ---- 汇总 ----
echo
[ -n "$OK_HOSTS" ] && log "已配置:$OK_HOSTS"
[ -n "$SKIP_HOSTS" ] && log "原本已免密:$SKIP_HOSTS"
if [ -n "$FAIL_HOSTS" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log "未免密:$FAIL_HOSTS"
    else
        log "失败:$FAIL_HOSTS"
    fi
    exit 1
fi
log "全部机器均已免密"
