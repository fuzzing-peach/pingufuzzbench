# DCMTK

## Source Repository

- [dcmtk](https://github.com/DCMTK/dcmtk)

## Supported version

| Date       | Tag         | Commit                                                                                 |
| ---------- | ----------- | -------------------------------------------------------------------------------------- |
| 2024-12-11 | DCMTK-3.6.9 | [ac00290]()                                                                            |
| 2023-10-27 | -           | [1549d8c](https://github.com/DCMTK/dcmtk/tree/1549d8ccccadad9ddd8a2bf75ff31eb554ee9dde) |

## Target

[dcmqrscp](https://support.dcmtk.org/docs-354/dcmqrscp.html)

| **特性**       | `dcmrecv`                 | `dcmqrscp`                      |
| -------------- | ------------------------- | ------------------------------- |
| **角色**       | Storage SCP（仅接收影像） | Query/Retrieve SCP（查询/检索） |
| **支持的服务** | C-STORE                   | C-FIND, C-MOVE, C-GET           |
| **数据管理**   | 直接保存到文件系统        | 依赖配置的数据库或文件系统      |
| **典型用途**   | 简单接收影像              | 构建功能完整的 PACS 服务器      |
