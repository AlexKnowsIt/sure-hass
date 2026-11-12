# Debugging

List the running containers:

```
docker ps
```

Find the addon container, then tail its logs. The name is `addon_local_sure` only when the addon is built locally; installed from this repository it is `addon_<repository-hash>_sure`, so let `docker ps` tell you:

```
docker ps --filter name=sure --format '{{.Names}}'
docker logs <name from above>
```

The addon runs four processes, so check that all appear in the logs: PostgreSQL (`database system is ready to accept connections`), Redis (`Ready to accept connections`), Sidekiq (`Booted Rails ... in "production" environment`) and Puma (`Listening on http://0.0.0.0:3000`). If any of them exits the addon stops as well, so Home Assistant restarts it.

A refusal to start with a PostgreSQL version message means the data directory was created by another major version; restore a dump from `/data/backups` instead (see `sure/README.md`).

Open a database shell:

```
docker exec -it <name> psql -h /run/postgresql -U sure sure
```
