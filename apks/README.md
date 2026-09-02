# APK archive

Every build worth keeping lives here, named so its identity is readable without
installing it:

    A.S-JUDGE_<version>_<applicationId>_<yyyymmdd-HHMM>.apk

Flutter writes each build to `tablet_app/build/app/outputs/apk/release/app-release.apk`
and overwrites it the next time, so a build that is not copied here is gone the
moment the next one finishes. That is how the version the tablets are running
stopped existing as a file.

Archive the current build with:

    node "tablet_app/../scripts/archive-apk.mjs"      # from the project root:
    node scripts/archive-apk.mjs

An APK you already have from somewhere else can simply be dropped in this folder.
The Tablets screen lists whatever is here, reading the name for its version and
application id, and falls back to the file name for anything it cannot parse.
