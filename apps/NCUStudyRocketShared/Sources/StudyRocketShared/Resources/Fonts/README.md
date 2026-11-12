# Optional poetry fonts

The unmodified Adobe Source Han Serif 2.003 **official CN region-specific** Regular and Bold OTF files are bundled under the SIL Open Font License 1.1 (see `OFL.txt`). They are not subset to fixed application strings or chat history. `SOURCE.json` pins the upstream commit, original URLs, exact file sizes and SHA-256 hashes.

The two font files total 23,720,788 bytes (22.62 MiB). Each contains 31,058 glyphs; Core Text inspection confirms all 20,992 Unicode BMP Unified CJK characters (U+4E00–U+9FFF), including traditional-character samples. This is not a claim to cover every rare extension-plane ideograph. Characters absent from the font retain the platform fallback cascade.

Ordinary controls, timetables, chat and input use the platform system font and its language fallback. These files are reserved for explicit `StudyTypography.poetryFont` / `studyPoetryTypography` content, currently the Mac seasonal verse and its detail view. Mobile has no poetry call site and does not register them for ordinary UI. Times New Roman is no longer forced anywhere in the app typography.

When poetry requests this face, fonts may be registered from the SwiftPM resource bundle into the current process; there is no runtime download or system-wide font installation. On macOS, an installed Songti SC is preferred. Missing or failed font registrations fall back to the system font. Font binaries and their provenance are unchanged from the earlier serif experiment.

The library package excludes these resources on Linux. Apple app packaging must include the generated `NCUStudyRocketShared_StudyRocketShared.bundle` resource bundle. No Apple commercial font file is redistributed.
