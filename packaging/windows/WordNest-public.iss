; Public builds share every installer setting with the private/local variant.
; package.py --public supplies the selected sanitized ProjectRoot, pubspec
; Version, WindowsVersion, staged OutputRoot and validated SupplementalFiles.
#define PublicBuild 1
#include "WordNest.iss"
