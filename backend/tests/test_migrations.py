"""DB-free checks of the Alembic chain: the database is created by `alembic upgrade head`.

No Postgres here: every migration runs against a fake `op` and inspector that keep the
tables, columns, indexes and foreign keys it creates. The real check is the CI job that
runs `alembic upgrade head` on an empty database before the integration tests.
"""

import copy
import importlib.util
import re
from pathlib import Path

import pytest
import sqlalchemy as sa

from app.models import Base

VERSIONS = Path(__file__).parents[1] / "alembic" / "versions"
BASELINE_TABLES = {
    "segments",
    "transcriptions",
    "conversations",
    "chunks",
    "entities",
    "digests",
    "chat_sessions",
    "api_keys",
}


def _load(path: Path):
    spec = importlib.util.spec_from_file_location(f"migration_{path.stem}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _migrations() -> list:
    return [_load(p) for p in sorted(VERSIONS.glob("[0-9][0-9][0-9]_*.py"))]


class _State:
    """What a fake database holds: tables -> columns / indexes / foreign keys."""

    def __init__(self):
        self.tables: dict[str, dict] = {}
        self.extensions: set[str] = set()

    def add_table(self, name, columns):
        assert name not in self.tables, f"{name} created twice"
        self.tables[name] = {"columns": {}, "indexes": [], "fks": []}
        for column, nullable in columns:
            self.add_column(name, column, nullable)

    def add_column(self, table, column, nullable=True):
        columns = self.tables[table]["columns"]
        assert column not in columns, f"{table}.{column} added twice"
        columns[column] = nullable


class _Inspector:
    def __init__(self, state: _State):
        self.state = state

    def get_table_names(self):
        return list(self.state.tables)

    def get_columns(self, table):
        return [{"name": c, "nullable": n} for c, n in self.state.tables[table]["columns"].items()]

    def get_indexes(self, table):
        return list(self.state.tables[table]["indexes"])

    def get_foreign_keys(self, table):
        return list(self.state.tables[table]["fks"])


_CREATE_TABLE = re.compile(r"CREATE TABLE (\w+) \((.*)\)\s*$", re.S)
_CREATE_INDEX = re.compile(
    r"CREATE (UNIQUE )?INDEX (\w+) ON (\w+)(?: USING \w+)? \((.*?)\)(?: WITH .*)?(?: WHERE .*)?$",
    re.S,
)
_NAMED_FK = re.compile(
    r"CONSTRAINT (\w+) FOREIGN KEY \((\w+)\) REFERENCES (\w+)\(id\)" r"(?: ON DELETE ([A-Z ]+))?"
)
_EXTENSION = re.compile(r'CREATE EXTENSION IF NOT EXISTS "?([\w-]+)"?')


class _Op:
    """The subset of alembic.op the migrations use, applied to a _State."""

    def __init__(self, state: _State):
        self.state = state
        self.calls: list[tuple] = []

    def get_bind(self):
        return self

    # Raw SQL (the 001 baseline)
    def execute(self, statement):
        sql = " ".join(str(statement).split()).rstrip(";")
        self.calls.append(("execute", sql))
        if m := _EXTENSION.match(sql):
            self.state.extensions.add(m.group(1))
        elif m := _CREATE_TABLE.match(sql):
            self._create_table_sql(m.group(1), m.group(2))
        elif m := _CREATE_INDEX.match(sql):
            cols = [part.split()[0] for part in m.group(4).split(",")]
            self.state.tables[m.group(3)]["indexes"].append(
                {"name": m.group(2), "column_names": cols, "unique": bool(m.group(1))}
            )
        elif sql.split()[0] in {"INSERT", "UPDATE", "DELETE"}:
            pass  # data backfills: no schema change
        else:
            raise AssertionError(f"unexpected SQL: {sql}")

    def _create_table_sql(self, table, body):
        parts = [p.strip() for p in re.split(r",(?![^()]*\))", body)]
        columns, fks = [], []
        for part in parts:
            if m := _NAMED_FK.match(part):
                fks.append((m.group(1), m.group(2), m.group(3), m.group(4)))
                continue
            name = part.split()[0]
            nullable = "NOT NULL" not in part and "PRIMARY KEY" not in part
            columns.append((name, nullable))
            if m := re.search(r"REFERENCES (\w+)\(id\)(?: ON DELETE (CASCADE|SET NULL))?", part):
                fks.append((f"{table}_{name}_fkey", name, m.group(1), m.group(2)))
        self.state.add_table(table, columns)
        for fk_name, column, referred, ondelete in fks:
            assert referred in self.state.tables, f"{table} references missing {referred}"
            self._add_fk(table, fk_name, column, referred, ondelete)

    def _add_fk(self, table, name, column, referred, ondelete):
        self.state.tables[table]["fks"].append(
            {
                "name": name,
                "constrained_columns": [column],
                "referred_table": referred,
                "referred_columns": ["id"],
                "options": {"ondelete": ondelete} if ondelete else {},
            }
        )

    # alembic.op operations (002+)
    def create_table(self, name, *items, **kw):
        self.calls.append(("create_table", name))
        cols = [
            (c.name, c.nullable and not c.primary_key) for c in items if isinstance(c, sa.Column)
        ]
        self.state.add_table(name, cols)
        for item in items:
            if isinstance(item, sa.ForeignKeyConstraint):
                referred = item.elements[0].target_fullname.split(".")[0]
                self._add_fk(name, item.name, item.column_keys[0], referred, item.ondelete)

    def add_column(self, table, column, **kw):
        self.calls.append(("add_column", table, column.name))
        self.state.add_column(table, column.name, column.nullable)

    def alter_column(self, table, column, nullable=None, **kw):
        self.calls.append(("alter_column", table, column))
        if nullable is not None:
            self.state.tables[table]["columns"][column] = nullable

    def create_index(self, name, table, columns, unique=False, **kw):
        self.calls.append(("create_index", name))
        assert name not in {i["name"] for i in self.state.tables[table]["indexes"]}
        self.state.tables[table]["indexes"].append(
            {"name": name, "column_names": list(columns), "unique": unique}
        )

    def drop_constraint(self, name, table, type_=None):
        self.calls.append(("drop_constraint", name))
        fks = self.state.tables[table]["fks"]
        fks[:] = [fk for fk in fks if fk["name"] != name]

    def create_foreign_key(self, name, table, referred, cols, ref_cols, ondelete=None):
        self.calls.append(("create_foreign_key", name))
        self._add_fk(table, name, cols[0], referred, ondelete)

    def drop_table(self, name):
        self.calls.append(("drop_table", name))
        del self.state.tables[name]


def _run(module, state: _State, monkeypatch) -> _Op:
    op = _Op(state)
    monkeypatch.setattr(module, "op", op)
    if hasattr(module, "sa_inspect"):
        monkeypatch.setattr(module, "sa_inspect", lambda bind: _Inspector(state))
    module.upgrade()
    return op


def test_every_migration_imports_and_the_chain_is_linear():
    modules = _migrations()
    assert [m.revision for m in modules] == [f"{i:03d}" for i in range(1, 35)]
    assert modules[0].down_revision is None
    for previous, current in zip(modules, modules[1:]):
        assert current.down_revision == previous.revision
    revisions = {m.revision for m in modules}
    downs = {m.down_revision for m in modules}
    assert len(revisions - downs) == 1  # one head


def test_baseline_creates_the_extensions_and_the_001_tables(monkeypatch):
    baseline = _load(VERSIONS / "001_baseline_schema.py")
    state = _State()
    op = _run(baseline, state, monkeypatch)

    assert state.extensions == {"uuid-ossp", "vector"}
    assert op.calls[0][1].startswith("CREATE EXTENSION")  # before any table uses them
    assert set(state.tables) == BASELINE_TABLES
    segments = state.tables["segments"]["columns"]
    # Columns added later by 002/003/006/007 are not in the baseline
    for later in ("audio_hash", "audio_energy", "speaker"):
        assert later not in segments
    assert segments["audio_path"] is False and segments["audio_size_bytes"] is False
    assert "speaker_label" not in state.tables["transcriptions"]["columns"]
    assert "kind" not in state.tables["chat_sessions"]["columns"]
    fk = state.tables["segments"]["fks"][0]
    assert (fk["name"], fk["referred_table"], fk["options"]) == (
        "fk_segments_conversation",
        "conversations",
        {},
    )
    indexes = {i["name"] for t in state.tables.values() for i in t["indexes"]}
    assert indexes == {
        "idx_segments_user_recorded",
        "idx_segments_status",
        "idx_segments_conversation",
        "idx_transcriptions_segment",
        "idx_conversations_user_time",
        "idx_chunks_conversation",
        "idx_chunks_embedding",
        "idx_entities_user_type",
        "idx_entities_name",
        "idx_entities_conversation",
        "idx_entities_embedding",
        "idx_digests_user_date",
        "idx_chat_sessions_user",
        "idx_api_keys_hash",
    }


def test_baseline_does_nothing_when_the_tables_exist(monkeypatch):
    baseline = _load(VERSIONS / "001_baseline_schema.py")
    state = _State()
    for table in BASELINE_TABLES:
        state.add_table(table, [("id", False)])
    op = _run(baseline, state, monkeypatch)
    assert op.calls == []


def test_baseline_creates_only_the_missing_tables(monkeypatch):
    baseline = _load(VERSIONS / "001_baseline_schema.py")
    state = _State()
    for table in BASELINE_TABLES - {"digests", "api_keys"}:
        state.add_table(table, [("id", False)])
    op = _run(baseline, state, monkeypatch)
    created = [c[1].split()[2] for c in op.calls if c[1].startswith("CREATE TABLE")]
    assert sorted(created) == ["api_keys", "digests"]


def test_baseline_downgrade_is_an_error():
    baseline = _load(VERSIONS / "001_baseline_schema.py")
    with pytest.raises(RuntimeError):
        baseline.downgrade()


def test_upgrade_head_from_an_empty_database_matches_the_models(monkeypatch):
    state = _State()
    for module in _migrations():
        _run(module, state, monkeypatch)

    assert set(state.tables) == set(Base.metadata.tables)
    for name, table in Base.metadata.tables.items():
        assert set(state.tables[name]["columns"]) == set(table.columns.keys()), name
    segments = state.tables["segments"]["columns"]
    assert segments["audio_path"] is True and segments["audio_size_bytes"] is True
    cascade = {
        (t, fk["constrained_columns"][0]): fk["options"].get("ondelete")
        for t in ("segments", "entities")
        for fk in state.tables[t]["fks"]
        if fk["referred_table"] == "conversations"
    }
    assert cascade == {
        ("segments", "conversation_id"): "CASCADE",
        ("entities", "conversation_id"): "CASCADE",
    }


def test_running_001_to_007_again_changes_nothing(monkeypatch):
    # 008 is left out: 004/005 would create again the tables it drops (never rerun)
    modules = _migrations()[:7]
    state = _State()
    for module in modules:
        _run(module, state, monkeypatch)
    before = copy.deepcopy(state.tables)
    for module in modules:
        op = _run(module, state, monkeypatch)
        # 006 re-applies "audio_path nullable" every time: harmless, nothing is created
        assert [c for c in op.calls if c[0] != "alter_column"] == [], module.revision
    assert state.tables == before


def test_migration_009_adds_the_conversation_emoji_once(monkeypatch):
    state = _State()
    for module in _migrations():
        _run(module, state, monkeypatch)
    assert "emoji" in state.tables["conversations"]["columns"]

    migration_009 = next(m for m in _migrations() if m.revision == "009")
    again = _run(migration_009, state, monkeypatch)

    assert again.calls == []


def test_migration_010_creates_mentions_backfills_them_and_is_not_rerun(monkeypatch):
    state = _State()
    calls = []
    for module in _migrations():
        calls = _run(module, state, monkeypatch).calls
        if module.revision == "010":
            break
    mentions = state.tables["entity_mentions"]
    assert {"entity_id", "conversation_id", "transcription_id"} <= set(mentions["columns"])
    assert any(
        sql.startswith("INSERT INTO entity_mentions") for kind, sql in calls if kind == "execute"
    )

    migration_010 = next(m for m in _migrations() if m.revision == "010")
    again = _run(migration_010, state, monkeypatch)

    assert again.calls == []


def test_migration_011_adds_photos_and_photo_chunks_once(monkeypatch):
    state = _State()
    for module in _migrations():
        _run(module, state, monkeypatch)
    photos = state.tables["photos"]["columns"]
    assert {"status", "source", "question", "image", "description", "answer"} <= set(photos)
    assert state.tables["chunks"]["columns"]["photo_id"] is True  # nullable

    migration_011 = next(m for m in _migrations() if m.revision == "011")
    again = _run(migration_011, state, monkeypatch)

    assert again.calls == []


def test_migration_021_adds_the_user_name_and_names_the_thread_echo(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "021":
            break
        _run(module, state, monkeypatch)
    migration_021 = next(m for m in _migrations() if m.revision == "021")

    op = _run(migration_021, state, monkeypatch)

    assert state.tables["users"]["columns"]["name"] is True  # nullable
    updates = [call[1] for call in op.calls if call[0] == "execute"]
    assert updates == ["UPDATE chat_sessions SET title = 'Echo' WHERE kind = 'voice'"]


def test_migration_023_creates_the_saved_tables(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "023":
            break
        _run(module, state, monkeypatch)
    migration_023 = next(m for m in _migrations() if m.revision == "023")

    op = _run(migration_023, state, monkeypatch)

    assert [c[1] for c in op.calls if c[0] == "create_table"] == ["saved_lists", "saved_items"]
    items = state.tables["saved_items"]
    assert items["columns"]["photo_id"] is True and items["columns"]["list_id"] is False
    ondelete = {
        fk["constrained_columns"][0]: fk["options"].get("ondelete") for fk in items["fks"]
    }
    # The photo and the conversation may go: the thing stays, with its text
    assert ondelete == {
        "list_id": "CASCADE",
        "photo_id": "SET NULL",
        "conversation_id": "SET NULL",
        "segment_id": "SET NULL",
    }
    lists = {i["name"]: i for i in state.tables["saved_lists"]["indexes"]}
    assert lists["ix_saved_lists_user_name"]["unique"] is True
    assert {"ix_saved_items_user_id", "ix_saved_items_list_id"} <= {
        i["name"] for i in items["indexes"]
    }


def test_migration_024_creates_the_place_visits(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "024":
            break
        _run(module, state, monkeypatch)
    migration_024 = next(m for m in _migrations() if m.revision == "024")

    op = _run(migration_024, state, monkeypatch)

    assert [c[1] for c in op.calls if c[0] == "create_table"] == ["place_visits"]
    visits = state.tables["place_visits"]
    # A stay still going has no departure yet
    assert visits["columns"]["left_at"] is True and visits["columns"]["arrived_at"] is False
    indexes = {i["name"]: i for i in visits["indexes"]}
    # One visit per stay the phone sends: its key
    assert indexes["ix_place_visits_user_key"]["unique"] is True
    assert indexes["ix_place_visits_user_key"]["column_names"] == ["user_id", "key"]
    assert indexes["ix_place_visits_user_arrived"]["column_names"] == ["user_id", "arrived_at"]
    assert visits["fks"] == []


def test_migration_025_adds_the_user_plan(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "025":
            break
        _run(module, state, monkeypatch)
    migration_025 = next(m for m in _migrations() if m.revision == "025")

    _run(migration_025, state, monkeypatch)

    # Every account has one: the existing ones start on free (the server default)
    assert state.tables["users"]["columns"]["plan"] is False


def test_migration_026_adds_modes_and_routine_runs(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "026":
            break
        _run(module, state, monkeypatch)
    migration_026 = next(m for m in _migrations() if m.revision == "026")

    _run(migration_026, state, monkeypatch)

    # Existing routines keep reporting every run: `always` is the server default
    assert state.tables["routines"]["columns"]["mode"] is False
    runs = state.tables["routine_runs"]
    assert runs["columns"]["text"] is True and runs["columns"]["status"] is False
    fk = runs["fks"][0]
    assert (fk["referred_table"], fk["options"].get("ondelete")) == ("routines", "CASCADE")
    indexes = {i["name"]: i["column_names"] for i in runs["indexes"]}
    assert indexes["ix_routine_runs_user_ran"] == ["user_id", "ran_at"]



def test_migration_027_adds_other_languages_and_translations(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "027":
            break
        _run(module, state, monkeypatch)
    migration_027 = next(m for m in _migrations() if m.revision == "027")

    _run(migration_027, state, monkeypatch)

    # Every account has the list, empty until the user adds a language
    assert state.tables["users"]["columns"]["other_languages"] is False
    translations = state.tables["transcription_translations"]
    assert translations["columns"]["text"] is False
    fk = translations["fks"][0]
    assert (fk["referred_table"], fk["options"].get("ondelete")) == ("transcriptions", "CASCADE")



def test_migration_028_adds_facts_and_documents(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "028":
            break
        _run(module, state, monkeypatch)
    migration_028 = next(m for m in _migrations() if m.revision == "028")

    _run(migration_028, state, monkeypatch)

    facts = state.tables["user_facts"]["columns"]
    assert facts["text"] is False and facts["conversation_id"] is True
    documents = state.tables["documents"]["columns"]
    assert documents["status"] is False and documents["error"] is True
    chunk_fk = state.tables["document_chunks"]["fks"][0]
    assert (chunk_fk["referred_table"], chunk_fk["options"].get("ondelete")) == (
        "documents", "CASCADE",
    )



def test_migration_029_adds_assistants(monkeypatch):
    state = _State()
    for module in _migrations():
        if module.revision >= "029":
            break
        _run(module, state, monkeypatch)
    migration_029 = next(m for m in _migrations() if m.revision == "029")

    _run(migration_029, state, monkeypatch)

    assistants = state.tables["assistants"]["columns"]
    assert assistants["name"] is False and assistants["notes"] is False
    for table in ("chat_sessions", "routines"):
        assert state.tables[table]["columns"]["assistant_id"] is True
        fk = next(f for f in state.tables[table]["fks"] if f["referred_table"] == "assistants")
        assert fk["options"].get("ondelete") == "SET NULL"


def test_migration_003_is_defined_once():
    source = (VERSIONS / "003_add_speaker_and_feedback.py").read_text(encoding="utf-8")
    assert source.count("def upgrade") == 1 and source.count("def downgrade") == 1
    assert source.count('revision: str = "003"') == 1
    assert "sa_inspect" in source


def test_schema_sql_is_reference_only_and_reflects_head():
    schema = Path(__file__).parents[2] / "docs" / "schema.sql"
    if not schema.exists():
        pytest.skip("docs/ is outside the backend container mount")
    sql = schema.read_text(encoding="utf-8")
    assert "Reference only: the database is created by Alembic (`alembic upgrade head`)" in sql
    created = set(re.findall(r"CREATE TABLE (?:IF NOT EXISTS )?(\w+)", sql))
    assert created == set(Base.metadata.tables)
    for gone in ("rules", "integrations"):
        assert f"CREATE TABLE {gone}" not in sql
    for column in ("speaker_label", "kind VARCHAR(10)", "audio_hash"):
        assert column in sql
