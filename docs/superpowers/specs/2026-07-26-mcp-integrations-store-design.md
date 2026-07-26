# MCP Integration Store — Design Spec

## Goal

Allow Echo to act on extracted knowledge by forwarding entities to external services (Todoist, Calendar, Notion, etc.) via MCP protocol. Simple toggle-based UI, zero-config defaults.

## User Experience

1. User opens "Integrations" in app
2. Sees list of available integrations (Todoist, Google Calendar, Notion, Telegram)
3. Taps one → enters API key/token → toggle ON
4. From now on: extracted tasks → auto-created in Todoist, events → Calendar, etc.
5. No rules to configure — preset mapping built-in

## Architecture

```
Worker: entity extracted
    ↓
Check: any active integration for this entity_type?
    ↓ yes
Automation Engine: call MCP tool
    ↓
MCP Server (subprocess or HTTP): execute action
    ↓
Result logged + optional notification to user
```

## Database Schema

```sql
CREATE TABLE integrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    provider TEXT NOT NULL,        -- 'todoist', 'google_calendar', 'notion', 'telegram'
    enabled BOOLEAN NOT NULL DEFAULT false,
    config JSONB NOT NULL DEFAULT '{}',  -- provider-specific config (api_key, workspace_id, etc.)
    entity_types TEXT[] NOT NULL,  -- which entity types trigger this: ['task'], ['event'], etc.
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_integrations_user ON integrations (user_id);
```

## Preset Mappings (built-in)

| Provider | Triggered by | Action |
|----------|-------------|--------|
| Todoist | task | Create task (name → title, due_date → due) |
| Google Calendar | event | Create event (name → title, event_date → date) |
| Notion | idea, note | Create page (name → title, content → body) |
| Telegram | all (digest) | Send daily digest message |

## API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | /api/integrations | List user's integrations (with status) |
| POST | /api/integrations | Create/enable an integration |
| PATCH | /api/integrations/{id} | Update config or toggle enabled |
| DELETE | /api/integrations/{id} | Remove integration |
| GET | /api/integrations/available | List available providers with metadata |

## Provider Registry (config file)

```json
// integrations/providers.json
[
  {
    "id": "todoist",
    "name": "Todoist",
    "icon": "check_circle",
    "description": "Auto-create tasks from conversations",
    "entity_types": ["task"],
    "config_fields": [
      {"key": "api_token", "label": "API Token", "type": "password", "required": true}
    ],
    "mcp_server": "todoist-mcp"
  },
  {
    "id": "google_calendar",
    "name": "Google Calendar",
    "icon": "calendar_today",
    "description": "Auto-create events mentioned in conversations",
    "entity_types": ["event"],
    "config_fields": [
      {"key": "credentials_json", "label": "Service Account JSON", "type": "file", "required": true}
    ],
    "mcp_server": "google-calendar-mcp"
  },
  {
    "id": "notion",
    "name": "Notion",
    "icon": "note",
    "description": "Save ideas and notes to your workspace",
    "entity_types": ["idea", "note"],
    "config_fields": [
      {"key": "api_key", "label": "Integration Token", "type": "password", "required": true},
      {"key": "database_id", "label": "Database ID", "type": "text", "required": true}
    ],
    "mcp_server": "notion-mcp"
  },
  {
    "id": "telegram",
    "name": "Telegram",
    "icon": "send",
    "description": "Receive daily digest via Telegram bot",
    "entity_types": ["digest"],
    "config_fields": [
      {"key": "bot_token", "label": "Bot Token", "type": "password", "required": true},
      {"key": "chat_id", "label": "Chat ID", "type": "text", "required": true}
    ],
    "mcp_server": "telegram-mcp"
  }
]
```

## Worker Integration

After entity extraction in `process_analysis()`:
```python
# After entities are saved
for entity in new_entities:
    await trigger_integrations(db, user_id, entity)
```

`trigger_integrations()`:
1. Query active integrations for this user + entity_type
2. For each match: call the MCP tool with entity data
3. Log result (success/failure)

## App UI (Integrations Screen)

- List of provider cards
- Each card: icon + name + description + toggle
- Tap card when disabled → modal with config fields → save → enabled
- When enabled: green badge, toggle to disable
- Simple, no complex flows

## Out of Scope (v1)

- OAuth flows (use API tokens instead)
- Custom automation rules
- Integration logs/history in UI
- Real-time sync (batch only, triggered on entity creation)
