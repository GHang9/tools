# tools

## Debian / Ubuntu 开启 root SSH 密码登录

脚本会提示设置 `root` 密码并允许 `root` 通过 SSH 使用密码登录，同时全局禁用 SSH 公钥认证、停用 `/etc/ssh/sshd_config.d/` 中的配置加载。现有用户、家目录和配置目录内的文件都会保留。

适用于采用标准 OpenSSH 配置且 `ssh.service` 正在运行的 Debian 和 Ubuntu。Ubuntu 24.04 可先用 `systemctl is-active ssh.service` 检查。如果只有 `ssh.socket` 在运行，脚本会在修改前退出。

在服务器的 **root 终端**运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHang9/tools/8fe512ee65c9b30e0cea2334a5dff27759380913/enable-root-ssh.sh)
```

脚本会备份并校验 SSH 配置，再重载服务。依赖密钥的 SSH 或 SFTP 新连接将无法使用公钥认证。执行后先保留当前 SSH 窗口，再开一个窗口测试 `root` 密码登录。
