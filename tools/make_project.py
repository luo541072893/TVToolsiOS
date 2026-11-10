#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 TVToolsiOS.xcodeproj/project.pbxproj。

手写 pbxproj 的 24 位 ID 很容易引用错，这里用脚本按固定规则生成，
保证 PBXBuildFile / PBXFileReference / PBXGroup / PBXSourcesBuildPhase 完全一致。
新增 Swift 文件后重跑本脚本即可。

运行：python3 tools/make_project.py
"""
import os
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "TVToolsiOS.xcodeproj")
SRC = os.path.join(ROOT, "TVToolsiOS")

BUNDLE_ID = "cn.tvtools.ios.app"
DEPLOY_TARGET = "16.0"


def oid(key: str) -> str:
    """由稳定 key 派生 24 位十六进制 ID"""
    return hashlib.md5(("tvtools:" + key).encode()).hexdigest()[:24].upper()


# 相对 TVToolsiOS/ 的 swift 源文件
SWIFT_FILES = [
    "App/TVToolsiOSApp.swift",
    "Views/ContentView.swift",
    "Views/AdvancedMenuView.swift",
    "Views/ConnectionView.swift",
    "Views/ChannelCheckView.swift",
    "ADB/ADBProtocol.swift",
    "ADB/ADBTransport.swift",
    "ADB/ADBAuthenticator.swift",
    "ADB/ADBClient.swift",
    "ADB/ADBSync.swift",
    "Features/Commands.swift",
    "Features/ChannelProbe.swift",
    "Support/AppSettings.swift",
    "Support/LogStore.swift",
    "Support/TVSession.swift",
]

for f in SWIFT_FILES:
    if not os.path.isfile(os.path.join(SRC, f)):
        raise SystemExit("缺少源文件：" + f)

ID = {
    "project": oid("project"),
    "target": oid("target"),
    "product": oid("product"),
    "mainGroup": oid("mainGroup"),
    "appGroup": oid("appGroup"),
    "productsGroup": oid("productsGroup"),
    "sources": oid("sourcesPhase"),
    "resources": oid("resourcesPhase"),
    "frameworks": oid("frameworksPhase"),
    "projConfigList": oid("projConfigList"),
    "targetConfigList": oid("targetConfigList"),
    "projDebug": oid("projDebug"),
    "projRelease": oid("projRelease"),
    "targetDebug": oid("targetDebug"),
    "targetRelease": oid("targetRelease"),
    "plist": oid("Info.plist"),
    "assets": oid("Assets.xcassets"),
}

GROUP_IDS = {}
for d in ["App", "Views", "ADB", "Features", "Support"]:
    GROUP_IDS[d] = oid("group:" + d)

file_ref = {}
build_file = {}
for f in SWIFT_FILES:
    file_ref[f] = oid("fileref:" + f)
    build_file[f] = oid("buildfile:" + f)

lines = []
w = lines.append

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")

# ---- PBXBuildFile ----
w("")
w("/* Begin PBXBuildFile section */")
for f in SWIFT_FILES:
    w(f"\t\t{build_file[f]} /* {os.path.basename(f)} in Sources */ = "
      f"{{isa = PBXBuildFile; fileRef = {file_ref[f]} /* {os.path.basename(f)} */; }};")
assets_build = oid("buildfile:Assets.xcassets")
w(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = "
  f"{{isa = PBXBuildFile; fileRef = {ID['assets']} /* Assets.xcassets */; }};")
w("/* End PBXBuildFile section */")

# ---- PBXFileReference ----
w("")
w("/* Begin PBXFileReference section */")
w(f"\t\t{ID['product']} /* TVToolsiOS.app */ = "
  "{isa = PBXFileReference; explicitFileType = wrapper.application; "
  "includeInIndex = 0; path = TVToolsiOS.app; sourceTree = BUILT_PRODUCTS_DIR; };")
w(f"\t\t{ID['plist']} /* Info.plist */ = "
  "{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
  "path = Info.plist; sourceTree = \"<group>\"; };")
w(f"\t\t{ID['assets']} /* Assets.xcassets */ = "
  "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
  "path = Assets.xcassets; sourceTree = \"<group>\"; };")
for f in SWIFT_FILES:
    w(f"\t\t{file_ref[f]} /* {os.path.basename(f)} */ = "
      "{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
      f"path = {os.path.basename(f)}; sourceTree = \"<group>\"; }};")
w("/* End PBXFileReference section */")

# ---- PBXFrameworksBuildPhase ----
w("")
w("/* Begin PBXFrameworksBuildPhase section */")
w(f"\t\t{ID['frameworks']} /* Frameworks */ = {{")
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")

# ---- PBXGroup ----
w("")
w("/* Begin PBXGroup section */")
w(f"\t\t{ID['mainGroup']} = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{ID['appGroup']} /* TVToolsiOS */,")
w(f"\t\t\t\t{ID['productsGroup']} /* Products */,")
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w(f"\t\t{ID['productsGroup']} /* Products */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{ID['product']} /* TVToolsiOS.app */,")
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w(f"\t\t{ID['appGroup']} /* TVToolsiOS */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for d in ["App", "Views", "ADB", "Features", "Support"]:
    w(f"\t\t\t\t{GROUP_IDS[d]} /* {d} */,")
w(f"\t\t\t\t{ID['plist']} /* Info.plist */,")
w(f"\t\t\t\t{ID['assets']} /* Assets.xcassets */,")
w("\t\t\t);")
w("\t\t\tpath = TVToolsiOS;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

for d in ["App", "Views", "ADB", "Features", "Support"]:
    members = [f for f in SWIFT_FILES if f.startswith(d + "/")]
    w(f"\t\t{GROUP_IDS[d]} /* {d} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for f in members:
        w(f"\t\t\t\t{file_ref[f]} /* {os.path.basename(f)} */,")
    w("\t\t\t);")
    w(f"\t\t\tpath = {d};")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
w("/* End PBXGroup section */")

# ---- PBXNativeTarget ----
w("")
w("/* Begin PBXNativeTarget section */")
w(f"\t\t{ID['target']} /* TVToolsiOS */ = {{")
w("\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {ID['targetConfigList']} /* Build configuration list for PBXNativeTarget \"TVToolsiOS\" */;")
w("\t\t\tbuildPhases = (")
w(f"\t\t\t\t{ID['sources']} /* Sources */,")
w(f"\t\t\t\t{ID['frameworks']} /* Frameworks */,")
w(f"\t\t\t\t{ID['resources']} /* Resources */,")
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t);")
w("\t\t\tname = TVToolsiOS;")
w("\t\t\tproductName = TVToolsiOS;")
w(f"\t\t\tproductReference = {ID['product']} /* TVToolsiOS.app */;")
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")
w("/* End PBXNativeTarget section */")

# ---- PBXProject ----
w("")
w("/* Begin PBXProject section */")
w(f"\t\t{ID['project']} /* Project object */ = {{")
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 1500;")
w("\t\t\t\tLastUpgradeCheck = 1500;")
w("\t\t\t\tTargetAttributes = {")
w(f"\t\t\t\t\t{ID['target']} = {{")
w("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
w("\t\t\t\t\t};")
w("\t\t\t\t};")
w("\t\t\t};")
w(f"\t\t\tbuildConfigurationList = {ID['projConfigList']} /* Build configuration list for PBXProject \"TVToolsiOS\" */;")
w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = (")
w("\t\t\t\ten,")
w("\t\t\t\tBase,")
w("\t\t\t\t\"zh-Hans\",")
w("\t\t\t);")
w(f"\t\t\tmainGroup = {ID['mainGroup']};")
w(f"\t\t\tproductRefGroup = {ID['productsGroup']} /* Products */;")
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w(f"\t\t\t\t{ID['target']} /* TVToolsiOS */,")
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")

# ---- PBXResourcesBuildPhase ----
w("")
w("/* Begin PBXResourcesBuildPhase section */")
w(f"\t\t{ID['resources']} /* Resources */ = {{")
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
w(f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")

# ---- PBXSourcesBuildPhase ----
w("")
w("/* Begin PBXSourcesBuildPhase section */")
w(f"\t\t{ID['sources']} /* Sources */ = {{")
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for f in SWIFT_FILES:
    w(f"\t\t\t\t{build_file[f]} /* {os.path.basename(f)} in Sources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")

# ---- XCBuildConfiguration ----
w("")
w("/* Begin XCBuildConfiguration section */")
common_proj = [
    "ALWAYS_SEARCH_USER_PATHS = NO;",
    "CLANG_ANALYZER_NONNULL = YES;",
    "CLANG_ENABLE_MODULES = YES;",
    "CLANG_ENABLE_OBJC_ARC = YES;",
    "ENABLE_STRICT_OBJC_MSGSEND = YES;",
    "GCC_C_LANGUAGE_STANDARD = gnu11;",
    "GCC_NO_COMMON_BLOCKS = YES;",
    "GCC_WARN_UNDECLARED_SELECTOR = YES;",
    "IPHONEOS_DEPLOYMENT_TARGET = " + DEPLOY_TARGET + ";",
    "MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;",
    "SDKROOT = iphoneos;",
    "SWIFT_VERSION = 5.0;",
]
for cfg, ident in [("Debug", ID["projDebug"]), ("Release", ID["projRelease"])]:
    w(f"\t\t{ident} /* {cfg} */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    for s in common_proj:
        w("\t\t\t\t" + s)
    if cfg == "Debug":
        w("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
        w("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
        w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
        w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
        w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
        w("\t\t\t\tENABLE_TESTABILITY = YES;")
        w("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = ( \"DEBUG=1\", \"$(inherited)\" );")
    else:
        w("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
        w("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
        w("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
        w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
        w("\t\t\t\tVALIDATE_PRODUCT = YES;")
    w("\t\t\t};")
    w(f"\t\t\tname = {cfg};")
    w("\t\t};")

target_common = [
    "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
    "CODE_SIGN_STYLE = Automatic;",
    "CURRENT_PROJECT_VERSION = 1;",
    "GENERATE_INFOPLIST_FILE = NO;",
    "INFOPLIST_FILE = TVToolsiOS/Info.plist;",
    "IPHONEOS_DEPLOYMENT_TARGET = " + DEPLOY_TARGET + ";",
    "MARKETING_VERSION = 1.0;",
    "PRODUCT_BUNDLE_IDENTIFIER = " + BUNDLE_ID + ";",
    "PRODUCT_NAME = \"$(TARGET_NAME)\";",
    "SWIFT_EMIT_LOC_STRINGS = YES;",
    "SWIFT_VERSION = 5.0;",
    "TARGETED_DEVICE_FAMILY = \"1,2\";",
]
for cfg, ident in [("Debug", ID["targetDebug"]), ("Release", ID["targetRelease"])]:
    w(f"\t\t{ident} /* {cfg} */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    for s in target_common:
        w("\t\t\t\t" + s)
    w("\t\t\t};")
    w(f"\t\t\tname = {cfg};")
    w("\t\t};")
w("/* End XCBuildConfiguration section */")

# ---- XCConfigurationList ----
w("")
w("/* Begin XCConfigurationList section */")
w(f"\t\t{ID['projConfigList']} /* Build configuration list for PBXProject \"TVToolsiOS\" */ = {{")
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{ID['projDebug']} /* Debug */,")
w(f"\t\t\t\t{ID['projRelease']} /* Release */,")
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w(f"\t\t{ID['targetConfigList']} /* Build configuration list for PBXNativeTarget \"TVToolsiOS\" */ = {{")
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{ID['targetDebug']} /* Debug */,")
w(f"\t\t\t\t{ID['targetRelease']} /* Release */,")
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w("/* End XCConfigurationList section */")

w("\t};")
w(f"\trootObject = {ID['project']} /* Project object */;")
w("}")

os.makedirs(PROJ, exist_ok=True)
out = os.path.join(PROJ, "project.pbxproj")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")

# ---- 共享 Scheme（xcodebuild -scheme / GitHub Actions 必需）----
SCHEME_DIR = os.path.join(PROJ, "xcshareddata", "xcschemes")
os.makedirs(SCHEME_DIR, exist_ok=True)
scheme_path = os.path.join(SCHEME_DIR, "TVToolsiOS.xcscheme")
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary"
               BlueprintIdentifier="{ID['target']}"
               BuildableName="TVToolsiOS.app"
               BlueprintName="TVToolsiOS"
               ReferencedContainer="container:TVToolsiOS.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">
   </ArchiveAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug">
   </AnalyzeAction>
</Scheme>
"""
with open(scheme_path, "w", encoding="utf-8") as fh:
    fh.write(scheme)

print("✅ 已生成", out)
print("✅ 已生成", scheme_path)
print("   Swift 源文件:", len(SWIFT_FILES))
print("   Bundle ID:", BUNDLE_ID, "| iOS 部署目标:", DEPLOY_TARGET)
