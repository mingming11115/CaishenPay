#!/usr/bin/env python3
"""Regenerate the native Xcode project using Python's standard library only.

Run from any working directory. App sources and bundled resources are discovered
from Apps/{iOS,Watch,Shared} and Resources; package sources belong to SwiftPM.
Stable object identifiers and sorted paths keep project regeneration reviewable.
This script never modifies application sources, resources, or signing settings.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "CaishenPay.xcodeproj"
OBJECTS: dict[str, dict] = {}


def identifier(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:24].upper()


def add(key: str, isa: str, **attributes) -> str:
    oid = identifier(key)
    value = {"isa": isa, **attributes}
    if oid in OBJECTS and OBJECTS[oid] != value:
        raise ValueError(f"Conflicting project object: {key}")
    OBJECTS[oid] = value
    return oid


def literal(value, depth=0) -> str:
    """OpenStep property-list output; quoting every string is unambiguous."""
    indent = "\t" * depth
    if isinstance(value, dict):
        rows = [f"{indent}\t{literal(k)} = {literal(v, depth + 1)};" for k, v in value.items()]
        return "{\n" + "\n".join(rows) + f"\n{indent}}}"
    if isinstance(value, list):
        if not value:
            return "()"
        return "(\n" + "\n".join(f"{indent}\t{literal(v, depth + 1)}," for v in value) + f"\n{indent})"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def file_type(path: Path) -> str:
    return {
        ".swift": "sourcecode.swift",
        ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements",
        ".xcassets": "folder.assetcatalog",
        ".jpg": "image.jpeg",
        ".jpeg": "image.jpeg",
        ".png": "image.png",
        ".pdf": "image.pdf",
        ".json": "text.json",
        ".xcprivacy": "text.xml",
    }.get(path.suffix.lower(), "folder" if path.is_dir() else "file")


def reference(path: Path) -> str:
    relative = path.relative_to(ROOT).as_posix()
    return add(f"file:{relative}", "PBXFileReference", lastKnownFileType=file_type(path),
               name=path.name, path=relative, sourceTree="SOURCE_ROOT")


def resource_paths() -> list[Path]:
    directory = ROOT / "Resources"
    if not directory.exists():
        return []
    # Asset catalogs and localized .lproj directories are copied/compiled as units.
    selected: list[Path] = []
    for path in sorted(directory.rglob("*")):
        if any(part.startswith(".") for part in path.relative_to(directory).parts):
            continue
        if any(parent in selected for parent in path.parents):
            continue
        if path.is_file() or path.suffix in {".xcassets", ".lproj", ".bundle"}:
            selected.append(path)
    return selected


def configuration_list(key: str, base: dict, *, project=False) -> str:
    configs = []
    for name in ("Debug", "Release"):
        values = dict(base)
        if project:
            values.update({"DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
                           "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
                           "ONLY_ACTIVE_ARCH": "YES" if name == "Debug" else "NO"})
            if name == "Debug":
                values.update({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG",
                               "ENABLE_TESTABILITY": "YES"})
            else:
                values.update({"SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
        configs.append(add(f"config:{key}:{name}", "XCBuildConfiguration", buildSettings=values, name=name))
    return add(f"configs:{key}", "XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def scheme(target_name: str) -> str:
    name = escape(target_name)
    target = identifier(f"target:{target_name}")
    buildable = f'''<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:CaishenPay.xcodeproj"/>'''
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        {buildable}
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables/>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


def main() -> None:
    package = add("package:WorkPayCore", "XCLocalSwiftPackageReference", relativePath="Packages/WorkPayCore")
    sources = {directory: sorted((ROOT / "Apps" / directory).rglob("*.swift"))
               for directory in ("iOS", "Watch", "Shared")}
    resources = resource_paths()
    source_groups = [add(f"group:{directory}", "PBXGroup", children=[reference(path) for path in paths],
                         name=directory, sourceTree="<group>") for directory, paths in sources.items()]
    app_group = add("group:Apps", "PBXGroup", children=source_groups, name="Apps", sourceTree="<group>")
    resource_group = add("group:Resources", "PBXGroup", children=[reference(path) for path in resources],
                         name="Resources", sourceTree="<group>")
    config_group = add("group:Config", "PBXGroup", children=[reference(path) for path in sorted((ROOT / "Config").glob("*")) if path.is_file()],
                       name="Config", sourceTree="<group>")
    package_group = add("group:Packages", "PBXGroup", children=[reference(ROOT / "Packages" / "WorkPayCore")],
                        name="Packages", sourceTree="<group>")
    products = {name: add(f"product:{name}", "PBXFileReference", explicitFileType="wrapper.application",
                          includeInIndex=0, path=f"{name}.app", sourceTree="BUILT_PRODUCTS_DIR")
                for name in ("CaishenPay", "CaishenWatch")}
    product_group = add("group:Products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
    main_group = add("group:main", "PBXGroup", children=[app_group, resource_group, config_group, package_group, product_group], sourceTree="<group>")
    project_configs = configuration_list("project", {
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES", "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17", "SWIFT_VERSION": "5.0",
        "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "WATCHOS_DEPLOYMENT_TARGET": "10.0",
    }, project=True)
    targets = []
    for target_name, directory, bundle_id, sdk, platforms, family in (
        ("CaishenPay", "iOS", "com.caishen.jixin", "iphoneos", "iphoneos iphonesimulator", "1"),
        ("CaishenWatch", "Watch", "com.caishen.jixin.watchkitapp", "watchos", "watchos watchsimulator", "4"),
    ):
        is_watch = directory == "Watch"
        dependency = add(f"package-product:{target_name}", "XCSwiftPackageProductDependency", package=package, productName="WorkPayCore")
        source_builds = [add(f"source-build:{target_name}:{path.relative_to(ROOT)}", "PBXBuildFile", fileRef=reference(path))
                         for path in sources[directory] + sources["Shared"]]
        resource_builds = [add(f"resource-build:{target_name}:{path.relative_to(ROOT)}", "PBXBuildFile", fileRef=reference(path))
                           for path in resources]
        framework_build = add(f"framework-build:{target_name}", "PBXBuildFile", productRef=dependency)
        phases = [
            add(f"sources:{target_name}", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0),
            add(f"frameworks:{target_name}", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[framework_build], runOnlyForDeploymentPostprocessing=0),
            add(f"resources:{target_name}", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0),
        ]
        target_dependencies = []
        if not is_watch:
            embed = add("embed:watch", "PBXBuildFile", fileRef=products["CaishenWatch"], settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
            phases.append(add("phase:embed-watch", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                              dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16,
                              files=[embed], name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0))
            proxy = add("proxy:watch", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1,
                        remoteGlobalIDString=identifier("target:CaishenWatch"), remoteInfo="CaishenWatch")
            target_dependencies.append(add("dependency:watch", "PBXTargetDependency", target=identifier("target:CaishenWatch"), targetProxy=proxy))
        settings = {
            "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0.0",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": f"Config/{directory}-Info.plist",
            "PRODUCT_BUNDLE_IDENTIFIER": bundle_id, "PRODUCT_NAME": "$(TARGET_NAME)",
            "SDKROOT": sdk, "SUPPORTED_PLATFORMS": platforms, "TARGETED_DEVICE_FAMILY": family,
            "SWIFT_EMIT_LOC_STRINGS": "YES", "ENABLE_PREVIEWS": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "SKIP_INSTALL": "YES" if is_watch else "NO",
        }
        if not is_watch:
            settings.update({"SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
                             "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO"})
        configs = configuration_list(target_name, settings)
        targets.append(add(f"target:{target_name}", "PBXNativeTarget", buildConfigurationList=configs,
                           buildPhases=phases, buildRules=[], dependencies=target_dependencies,
                           name=target_name, packageProductDependencies=[dependency], productName=target_name,
                           productReference=products[target_name], productType="com.apple.product-type.application"))
    project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2700",
                  "TargetAttributes": {target: {"CreatedOnToolsVersion": "27.0"} for target in targets}},
                  buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
                  hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group,
                  packageReferences=[package], productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)
    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56,
                "objects": dict(sorted(OBJECTS.items())), "rootObject": project}
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + literal(document) + "\n", encoding="utf-8")
    shared = PROJECT / "xcshareddata" / "xcschemes"
    shared.mkdir(parents=True, exist_ok=True)
    for name in ("CaishenPay", "CaishenWatch"):
        (shared / f"{name}.xcscheme").write_text(scheme(name), encoding="utf-8")
    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"/></Workspace>\n', encoding="utf-8")
    print(f"Generated {PROJECT.name}: {sum(map(len, sources.values()))} Swift source files, {len(resources)} resource items; schemes CaishenPay and CaishenWatch.")


if __name__ == "__main__":
    main()
