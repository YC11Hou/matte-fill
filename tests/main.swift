import Foundation

// Entry of the offline checks: `tests-bin 1 2 3` runs those requirements' checks (tests/README.md).
let which = Set(CommandLine.arguments.dropFirst())
if which.contains("1") { print("1. external display untouched"); runExternal() }
if which.contains("2") { print("2. system animations untouched"); runAnimation() }
if which.contains("3") { print("3. built-in display: every black area becomes the fill"); runColor() }
print(failures == 0 ? "checks: all passed" : "checks: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
