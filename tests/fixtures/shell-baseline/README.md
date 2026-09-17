# Historical shell compatibility fixture

Frozen phase-one implementation, retained only to test journal compatibility
and document pre-migration behavior. These files are never installed or loaded
by the native runtime. Native behavior is covered by NotifyCore tests and
`tests/test_native_hooks.py`; passing this fixture suite is not native coverage.
