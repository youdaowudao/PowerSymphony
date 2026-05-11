# `bin/symphony_start` 配置说明

`bin/symphony_start` 支持两种启动方式：

1. 仓库内直接运行：
   - 如果脚本位于仓库自己的 `bin/` 目录中，会自动把仓库根识别为脚本上一级目录
   - 然后使用 `<repo>/elixir/WORKFLOW.md`
2. 脚本复制到系统 `bin` 后运行：
   - 不再猜测任何固定绝对路径
   - 这时必须显式设置 `POWERSYMPHONY_ROOT=/path/to/powersymphony`

未能自动发现 root、且未设置 `POWERSYMPHONY_ROOT` 时，脚本会直接报错，并提示使用仓库内的 `bin/symphony_start` 或显式设置 `POWERSYMPHONY_ROOT`。

## Linear token 文件

- 默认读取路径：`~/.config/linear/linear_api_key.token`
- 文件内容：纯 token 文本，不带引号、不带 `export` 前缀
- 读取行为：启动时只去掉前后空白，再注入为 `LINEAR_API_KEY`；中间内容保持原样
- 优先级：如果进程环境里已经显式设置 `LINEAR_API_KEY`，则无论是否为空字符串，都优先使用显式环境值，不读取文件

建议权限：

```bash
mkdir -p ~/.config/linear
chmod 700 ~/.config/linear
printf '%s\n' 'your-linear-token' > ~/.config/linear/linear_api_key.token
chmod 600 ~/.config/linear/linear_api_key.token
```

## 默认值

- 默认端口：`4000`
- 默认 logs root：
  - 若设置了 `XDG_STATE_HOME`：`${XDG_STATE_HOME}/powersymphony`
  - 否则：`${HOME}/.local/state/powersymphony`

## 可覆盖项

- `POWERSYMPHONY_ROOT`：覆盖仓库根目录
- `LINEAR_API_KEY`：显式覆盖 token 文件
- `--logs-root <path>`：覆盖默认日志目录
- `--port <port>`：覆盖默认端口 `4000`

## 帮助命令

```bash
symphony_start --help
```
