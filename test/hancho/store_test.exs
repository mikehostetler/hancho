defmodule Hancho.StoreTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{SQLite, Store}

  test "migrates once and rejects a newer schema without changing it" do
    path = Path.join(temporary_directory!(), "state.sqlite3")
    assert :ok = Store.migrate(path)
    assert :ok = Store.migrate(path)
    assert {:ok, 3} = SQLite.scalar(path, "PRAGMA user_version;")

    assert :ok = SQLite.execute(path, "PRAGMA user_version = 99;")
    assert {:error, error} = Store.migrate(path)
    assert error.code == :newer_database_schema
    assert {:ok, 99} = SQLite.scalar(path, "PRAGMA user_version;")
  end

  test "migrates an existing schema-one database without losing its facts" do
    path = Path.join(temporary_directory!(), "old.sqlite3")

    assert :ok =
             SQLite.execute(
               path,
               "CREATE TABLE preserved (value TEXT); INSERT INTO preserved VALUES ('kept'); PRAGMA user_version = 1;"
             )

    assert :ok = Store.migrate(path)
    assert {:ok, 3} = SQLite.scalar(path, "PRAGMA user_version;")
    assert {:ok, "kept"} = SQLite.scalar(path, "SELECT value FROM preserved;")
    assert {:ok, 0} = SQLite.scalar(path, "SELECT COUNT(*) FROM delivery_requests;")
  end

  test "rolls back an incomplete transaction" do
    path = Path.join(temporary_directory!(), "transaction.sqlite3")
    assert :ok = SQLite.execute(path, "CREATE TABLE facts (value TEXT);")

    assert {:error, _error} =
             SQLite.execute(
               path,
               "BEGIN; INSERT INTO facts VALUES ('kept-out'); SELECT missing FROM nowhere; COMMIT;"
             )

    assert {:ok, 0} = SQLite.scalar(path, "SELECT count(*) FROM facts;")
  end

  test "rolls back a failed schema migration and keeps the prior schema usable" do
    path = Path.join(temporary_directory!(), "failed-migration.sqlite3")

    assert :ok =
             SQLite.execute(
               path,
               "CREATE TABLE preserved (value TEXT); INSERT INTO preserved VALUES ('kept'); CREATE TABLE standard_work_proposals (wrong TEXT); PRAGMA user_version = 2;"
             )

    assert {:error, _failure} = Store.migrate(path)
    assert {:ok, 2} = SQLite.scalar(path, "PRAGMA user_version;")
    assert {:ok, "kept"} = SQLite.scalar(path, "SELECT value FROM preserved;")

    assert {:ok, nil} =
             SQLite.scalar(
               path,
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'delivery_requests';"
             )
  end

  test "quotes SQL text and null values" do
    assert SQLite.quote("owner's") == "'owner''s'"
    assert SQLite.quote(nil) == "NULL"
  end
end
