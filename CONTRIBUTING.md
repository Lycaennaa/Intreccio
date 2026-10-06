# Contributing

See [DEVELOPMENT.md](DEVELOPMENT.md) for source setup, builds, and checks.

## Workflow

Use GitHub Issues to discuss a bug or proposed change, then open a pull request with a focused diff. Keep generated Xcode project changes reproducible from `project.yml`; never hand-edit `Intreccio.xcodeproj/project.pbxproj`.

## Pull requests

Describe the problem and change, user-visible impact, limitations, release impact, and checks run. Update user documentation when behavior changes. Run `just ci` before requesting review.

- AI use (required): list the tools and models used, what they assisted with, and reasoning level where known. State `None` if no AI was used. Review and test generated content before submitting it.
