#!/bin/bash
# 在 Debian 上启用 root 密码登录，停用 SSH 公钥认证及 sshd_config.d。
set -euo pipefail

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || fail "请执行 sudo bash $0"
[[ $(id -u root) == 0 ]] || fail 'root 账号的 UID 不是 0。请检查系统账号配置。'
(( $# == 0 )) || fail '此脚本不接收参数。请按 passwd 提示输入密码。'
[[ -t 0 ]] || fail '请在交互式终端中执行。'

config=/etc/ssh/sshd_config
sshd=/usr/sbin/sshd
marker='# BEGIN enable-root-ssh.sh'
[[ -x $sshd && -f $config && ! -L $config ]] || fail '未找到标准的 OpenSSH 服务或配置文件。'
systemctl is-active --quiet ssh.service || fail 'Debian 的 ssh.service 当前未运行。'

# 防止脚本同时运行。候选文件与原配置位于同一文件系统。
exec 9>/run/lock/enable-root-ssh.lock
flock -n 9 || fail '已有一个实例正在运行。'
umask 077
work=$(mktemp -d /etc/ssh/.enable-root-ssh.XXXXXX)
restore_config=0

cleanup() {
    local status=$?
    trap - EXIT
    if (( restore_config )); then
        if mv -fT -- "$work/original" "$config"; then
            printf '已恢复原 SSH 配置。\n' >&2
            systemctl reload ssh.service || printf '原配置已写回，但 SSH 重载失败。请在当前终端检查 ssh.service。\n' >&2
        else
            printf '自动恢复失败。请使用备份 %s 手动恢复。\n' "$backup" >&2
        fi
    fi
    rm -rf -- "$work"
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp -p -- "$config" "$work/original"
"$sshd" -t -f "$work/original" || fail '当前 SSH 配置校验失败。'

# 同时覆盖全局与主配置中已有的 Match 公钥认证设置。保留原行供核对。
cp -p -- "$work/original" "$work/candidate"
awk '
    BEGIN { print "PubkeyAuthentication no" }
    {
        directive = $0
        sub(/^[[:space:]]+/, "", directive)
        keyword = tolower(directive)
        if (keyword ~ /^pubkeyauthentication([[:space:]]|=)/) {
            if (NR == 1 && $0 == "PubkeyAuthentication no") next
            print "# " $0
            next
        }
        if (keyword ~ /^include([[:space:]]|=)/) {
            sub(/^[^[:space:]=]+[[:space:]]*(=[[:space:]]*)?/, "", directive)
            sub(/[[:space:]]*#.*/, "", directive)
            sub(/[[:space:]]+$/, "", directive)
            if (directive !~ /^"?((\/etc\/ssh\/)?sshd_config\.d\/[^"\/[:space:]]+)"?$/) {
                print "发现非标准或组合 Include，第 " NR " 行。请先检查该规则。" > "/dev/stderr"
                exit 1
            }
            print "# " $0
            next
        }
        print
    }
' "$work/original" > "$work/candidate" || fail '未修改 SSH 配置。'

backup=''
if ! grep -Fxq -- "$marker" "$work/original"; then
    printf '\n%s\n' "$marker" >> "$work/candidate"
    cat >> "$work/candidate" <<'SSHD'
Match User root
    PermitRootLogin yes
    PasswordAuthentication yes
# END enable-root-ssh.sh
SSHD
fi

# 从现有 SSH 会话执行时，按当前连接的源地址和端口检查 Match。
read -r client_ip client_port server_ip server_port <<< "${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}"
"$sshd" -t -f "$work/candidate" || fail '新配置校验失败。'
original_global=$("$sshd" -T -f "$work/original") || fail '无法读取原 SSH 配置。'
candidate_global=$("$sshd" -T -f "$work/candidate") || fail '无法读取新 SSH 配置。'
listener_pattern='^(port|listenaddress|addressfamily) '
if [[ $(grep -E "$listener_pattern" <<< "$original_global" | sort) != \
      "$(grep -E "$listener_pattern" <<< "$candidate_global" | sort)" ]]; then
    fail '停用配置目录会改变 SSH 端口或监听地址。请先把相关设置移到主配置，再重新运行。'
fi
effective=$("$sshd" -T -f "$work/candidate" \
    -C "user=root,host=$client_ip,addr=$client_ip,laddr=$server_ip,lport=$server_port") \
    || fail '无法读取 root 的有效 SSH 配置。'
if ! grep -Fxq 'permitrootlogin yes' <<< "$effective" ||
   ! grep -Fxq 'passwordauthentication yes' <<< "$effective" ||
   ! grep -Fxq 'pubkeyauthentication no' <<< "$effective" ||
   ! grep -Eq '^authenticationmethods (any$|([^ ]+ )*password( |$))' <<< "$effective"; then
    printf '%s\n' "$effective" | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|authenticationmethods) ' >&2
    fail '现有认证规则阻止预期的 root 密码登录。请先检查上述配置。'
fi

if ! cmp -s -- "$work/original" "$work/candidate"; then
    backup=$(mktemp "${config}.root-login.bak.XXXXXX")
    cp -p -- "$work/original" "$backup"
    printf '原 SSH 配置备份在 %s\n' "$backup"
fi

printf '请设置 root 密码。输入时终端不会显示密码。\n'
passwd root || fail 'root 密码设置失败，SSH 配置尚未修改。'

# 在写入前检查管理员是否在设置密码期间改过主配置。
cmp -s -- "$work/original" "$config" || fail 'SSH 主配置在运行期间发生变化。root 密码已设置，请重新检查配置。'
if [[ -n $backup ]]; then
    restore_config=1
    mv -fT -- "$work/candidate" "$config"
fi
systemctl reload ssh.service || fail 'SSH 重载失败。root 密码已设置。'
restore_config=0

printf '已设置 UID 0 的 root 密码并重载 SSH。公钥认证及 sshd_config.d 加载已停用。\n'
printf '请保留当前会话，在另一个窗口测试 root 密码登录。\n'
