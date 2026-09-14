---
name: jira
description: Use Symphony's jira_rest tool to read and update Jira Cloud issues during runner sessions.
---

# Jira REST

Use the `jira_rest` tool. Symphony supplies Jira auth and accepts only relative `/rest/api/3/` paths.

Tool input:

```json
{
  "method": "GET",
  "path": "/rest/api/3/issue/PLAT-123",
  "query": {},
  "body": null
}
```

## Issue work

- Read an issue with `GET /rest/api/3/issue/{key}`. Request only needed fields through `query.fields`.
- Read comments with `GET /rest/api/3/issue/{key}/comment`.
- Add a comment with `POST /rest/api/3/issue/{key}/comment` and an Atlassian Document Format body.
- Edit a comment with `PUT /rest/api/3/issue/{key}/comment/{commentId}`.
- List transitions with `GET /rest/api/3/issue/{key}/transitions` before changing state.
- Transition with `POST /rest/api/3/issue/{key}/transitions` and body `{"transition":{"id":"..."}}`.

Jira descriptions and comment bodies use Atlassian Document Format, not Markdown. Preserve existing content you do not own. Treat non-2xx tool output as failure and report the response body.
