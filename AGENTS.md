# Civilight development policy

- Write all project scripts in Dart, not shell. Invoke external commands from Dart with explicit argument lists.
- Commit changes frequently in small, coherent commits. Keep unrelated changes in separate commits.
- After every push, monitor the CI runs for the pushed commit until they finish. Report the results, link to the runs and relevant artifacts, and investigate any failures.
