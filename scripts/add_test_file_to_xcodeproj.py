#!/usr/bin/env python3
"""Register a Swift test file in the FluidDictationIntegrationTests target.

usage: scripts/add_test_file_to_xcodeproj.py <FileName.swift>

App sources under Sources/Fluid are a synchronized folder and need no
registration; the test target uses explicit file references.
"""
import secrets
import sys

PBXPROJ = "Fluid.xcodeproj/project.pbxproj"
GROUP_ANCHOR = "980330F3CE464336ADCE3E23 /* TemperatureSupportTests.swift */,"
PHASE_ANCHOR = "272BFB5CB271489892CAE50C /* TemperatureSupportTests.swift in Sources */,"

def new_id(text):
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in text:
            return candidate

def main():
    name = sys.argv[1]
    text = open(PBXPROJ).read()
    if "/* %s */ = {isa = PBXFileReference" % name in text:
        sys.exit("%s already registered" % name)
    file_id, build_id = new_id(text), new_id(text)
    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (build_id, name, file_id, name),
        1,
    )
    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>"; };\n'
        % (file_id, name, name),
        1,
    )
    for anchor, entry in ((GROUP_ANCHOR, "%s /* %s */," % (file_id, name)),
                          (PHASE_ANCHOR, "%s /* %s in Sources */," % (build_id, name))):
        idx = text.index(anchor)
        indent = text[text.rfind("\n", 0, idx) + 1:idx]
        text = text[:idx + len(anchor)] + "\n" + indent + entry + text[idx + len(anchor):]
    open(PBXPROJ, "w").write(text)
    print("registered", name)

main()
