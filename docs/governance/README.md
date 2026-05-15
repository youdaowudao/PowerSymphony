# 文档治理入口

本目录是**可复用规则层**。

如果你要把这套文档规范复制到新仓库，先看这里，再看下面这些文件：

- [documentation-taxonomy.md](./documentation-taxonomy.md)
- [reusable-repository-documentation-standard.md](./reusable-repository-documentation-standard.md)
- [repository-bootstrap-guide.md](./repository-bootstrap-guide.md)
- [verification-layering.md](./verification-layering.md)
- [templates/README.md](./templates/README.md)

## 这个目录负责什么

- 定义文档分类
- 定义文档放哪里
- 定义谁该看什么
- 定义新仓库怎么起步
- 定义质量门禁和验证写法
- 提供可复制模板

## 这个目录不负责什么

- 不负责当前仓库每轮任务的执行细则
- 不负责单次 change 的实施步骤
- 不负责某个仓库的系统规格正文

这些内容分别应去：

- 本仓库执行规则：`AGENTS.md`
- 当前仓库长期主题：`docs/initiatives/`
- 单次高风险变更：`docs/changes/`

## 写作者路由

- 想改“文档分类 / 命名 / 路由”：
  - 改 `documentation-taxonomy.md`
- 想改“新仓库如何起步”：
  - 改 `repository-bootstrap-guide.md`
- 想改“质量门禁 / 验证分层”：
  - 改 `verification-layering.md`
- 想改“可复制模板”：
  - 改 `templates/`
