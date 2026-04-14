# Task Completion Checklist

1. Update TASKS.md, SPEC.md, README.md if functionality changed
2. Ask before tagging/releasing (unless instructed otherwise)
3. Test locally: `make restartlocal` then `make testlocal*`
4. Editing app.psgi requires container restart
5. Editing cron-scripts requires `make rebuildlocal`
6. No automated test suite exists - manual curl testing only
