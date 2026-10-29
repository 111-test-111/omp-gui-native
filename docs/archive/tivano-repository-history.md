# Repository history

> 历史记录：仅代表原文所列日期、版本及验收范围，不是当前操作指南。 本文属于 Tivano 上游历史，所述 provider、发布、镜像或历史迁移流程不适用于 OMP GUI；部分脚本已删除或禁用。 当前入口见[文档索引](../README.md)和[功能状态与验收边界](../status.md)。

Tivano is based on Droppy Code. The source, license notices, and attribution
remain in this repository; removing upstream Git commits does not change
the ownership or licensing of that source.

On 2026-10-08, the maintainer explicitly authorized a history migration
before making the repository public. The repository retains the maintainer’s
Tivano development and publication commits, with inherited commit ancestry
removed. Author and committer metadata use the GitHub identity `elijah7x`
and its GitHub noreply address.

Historical snapshots were sanitized: private icon delivery directories and
stale internal audit documents were removed, hardcoded maintainer emails
were replaced with the config/env-based credits implementation, and old
onboarding images were replaced with the current generated captures.
These historical snapshots are edited records and are not build-tested
representations of the original revisions. The final application source
matches the audited Dev 0.1.5 source; this migration does not change either
edition’s version or installed application.

The original history and the old-to-new commit map are kept in a private
archive outside the repository. Old task worktrees must not be merged or
pushed into this rewritten history; recreate future tasks from the new
main or dev branch.
