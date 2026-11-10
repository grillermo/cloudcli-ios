# frozen_string_literal: true

# ipa_builder.rb
#
# Builds an ad-hoc-signed CloudCLI .ipa from source, together with the OTA
# manifest.plist that an `itms-services://` link points at. Used by ../../deploy.
#
# The .ipa is signed with the paid Apple Developer Program team in
# Config/Local.xcconfig (DEVELOPMENT_TEAM). That is what lets iOS install it
# straight from Safari over an `itms-services://` link -- no AltStore, no cable,
# and a signature good for a year instead of the free tier's 7 days. The price is
# that an Ad Hoc profile only covers **devices registered on the portal**: a
# device whose UDID was added after this .ipa was built cannot install it, so
# adding a device means registering it and then re-running ../../deploy.
#
# Set CLOUDCLI_UNSIGNED=1 to fall back to an unsigned archive. That build cannot
# be installed from Safari; it exists so a broken signing setup does not block
# producing a binary.

require "fileutils"
require "shellwords"
require "tmpdir"

module IpaBuilder
  # --- per-app settings ------------------------------------------------------
  APP_NAME    = "CloudCLI"            # display name: install page, release tag message, published .ipa name
  PRODUCT_NAME = "Telescopure"        # the target's PRODUCT_NAME: names the built .app and the exported .ipa
  APP_SLUG    = "cloudcli"            # release tags and the pinned file names
  ENV_PREFIX  = "CLOUDCLI"            # CLOUDCLI_UPLOAD_BASE, CLOUDCLI_UNSIGNED, ...
  SCHEME      = "Telescopure"
  PROJECT     = "Telescopure.xcodeproj"
  ICON_SOURCE = "Telescopure/Assets.xcassets/AppIcon.appiconset/icon.png" # the 1024 px icon
  GIT_REMOTE  = "origin"
  # ---------------------------------------------------------------------------

  REPO_ROOT  = File.expand_path(File.join(__dir__, "..", ".."))
  PROJECT_PBXPROJ = File.join(REPO_ROOT, PROJECT, "project.pbxproj")
  XCCONFIGS  = [
    File.join(REPO_ROOT, "Config", "Local.xcconfig"),
    File.join(REPO_ROOT, "Config", "#{APP_NAME}.xcconfig"),
  ].freeze

  module_function

  # Plain `def ... end` throughout (no endless methods): over a non-interactive
  # SSH session the macmini's `ruby` is the system Ruby 2.6.
  def bold(str)
    "\e[1m#{str}\e[0m"
  end

  def green(str)
    "\e[32m#{str}\e[0m"
  end

  def red(str)
    "\e[31m#{str}\e[0m"
  end

  def step(msg)
    puts "\n#{bold("==> #{msg}")}"
  end

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:)
    puts "    $ #{cmd}"
    system(cmd, chdir: chdir) or die("command failed: #{cmd}")
  end

  def env(name)
    ENV["#{ENV_PREFIX}_#{name}"]
  end

  def unsigned?
    env("UNSIGNED") == "1"
  end

  # A build setting as Xcode resolves it: Config/Local.xcconfig (gitignored,
  # personal) wins over the committed defaults in Config/CloudCLI.xcconfig, so a
  # fresh clone still builds.
  def xcconfig_value(key)
    XCCONFIGS.each do |path|
      next unless File.exist?(path)

      value = File.read(path)[/^\s*#{key}\s*=[ \t]*(\S*)/, 1]
      return value if value && !value.empty?
    end
    nil
  end

  def bundle_id
    xcconfig_value("#{ENV_PREFIX}_BUNDLE_ID")
  end

  # xcodebuild needs a full Xcode, not the Command Line Tools. Honour an existing
  # DEVELOPER_DIR, otherwise point at the newest /Applications/Xcode*.app.
  def resolve_developer_dir
    dir = ENV["DEVELOPER_DIR"]
    return dir if dir && Dir.exist?(dir)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    die("no Xcode.app found; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  # MARKETING_VERSION out of project.pbxproj (source of truth for the app
  # version). All configs/targets share one value, so the first match is
  # authoritative.
  def marketing_version
    m = File.read(PROJECT_PBXPROJ)[/^\s*MARKETING_VERSION\s*=\s*([\d.]+);/, 1]
    die("no MARKETING_VERSION in #{PROJECT_PBXPROJ}") unless m
    m
  end

  def current_project_version
    m = File.read(PROJECT_PBXPROJ)[/^\s*CURRENT_PROJECT_VERSION\s*=\s*(\d+);/, 1]
    die("no CURRENT_PROJECT_VERSION in #{PROJECT_PBXPROJ}") unless m
    m
  end

  # Unlocks the keychain with the login password stored on this Mac, so an agent
  # can deploy over SSH without anyone typing it. Shared by every app.
  UNLOCK_SCRIPT = File.expand_path("~/c/agents-configs/bin/unlock-codesign-keychain.sh")

  # Over SSH (or after the Mac sleeps) the login keychain is locked, and
  # codesign cannot use the signing key: the archive then dies at its first
  # CodeSign step with errSecInternalComponent, after minutes of compiling.
  # Probe by signing a throwaway binary. If that fails, unlock with
  # UNLOCK_SCRIPT, and only without it (or when it fails) fall back to
  # `security unlock-keychain`, which prompts for the login password.
  def ensure_codesign_can_sign!
    return if unsigned?

    probe = File.join(Dir.tmpdir, "#{APP_NAME}-codesign-probe-#{Process.pid}")
    FileUtils.cp("/usr/bin/true", probe)
    sign = "codesign -f -s 'Apple Development' #{Shellwords.escape(probe)} >/dev/null 2>&1"
    return if system(sign)
    return if File.executable?(UNLOCK_SCRIPT) && system(UNLOCK_SCRIPT)

    puts red("    codesign cannot use your signing key -- the login keychain is locked.")
    keychain = File.expand_path("~/Library/Keychains/login.keychain-db")
    system("security unlock-keychain #{Shellwords.escape(keychain)}") or
      die("could not unlock the login keychain")
    system(sign) or
      die("codesign still fails after unlocking; try: codesign -f -s 'Apple Development' /some/file")
  ensure
    FileUtils.rm_f(probe) if probe
  end

  # The Apple Developer team the .ipa is signed for. Config/Local.xcconfig is the
  # source of truth; CLOUDCLI_TEAM_ID overrides it for a one-off.
  def team_id
    id = env("TEAM_ID") || xcconfig_value("DEVELOPMENT_TEAM")
    die("no DEVELOPMENT_TEAM in Config/Local.xcconfig and no #{ENV_PREFIX}_TEAM_ID set") unless id
    id
  end

  def xml_escape(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # ExportOptions.plist for `xcodebuild -exportArchive`.
  #
  # `release-testing` re-signs the archive with the team's *distribution*
  # certificate against an Ad Hoc provisioning profile, which embeds the UDIDs
  # registered on the portal. It is Xcode 15.3+'s name for what used to be
  # `ad-hoc`.
  #
  # Automatic signing will create the certificate and the profile on its own,
  # but it will NOT create the App ID. Register the bundle ID as an Identifier on
  # the portal first, or this export hits the "no profiles found" failure a
  # brand-new bundle ID gets.
  #
  # The `manifest` dict is why we export at all rather than zipping a Payload/
  # by hand: it makes xcodebuild emit the `manifest.plist` that an
  # `itms-services://` link points at, so the OTA manifest can never drift
  # from the binary it describes. Its appURL must be the .ipa's final public
  # URL, which the caller knows before the build.
  #
  # thinning `<none>` keeps it one universal .ipa; a thinned export produces
  # per-device variants that a single download URL cannot serve.
  def export_options_plist(path, manifest:)
    entries = [
      "<key>method</key><string>release-testing</string>",
      "<key>teamID</key><string>#{xml_escape(team_id)}</string>",
      "<key>signingStyle</key><string>automatic</string>",
      "<key>stripSwiftSymbols</key><true/>",
      "<key>thinning</key><string>&lt;none&gt;</string>",
      "<key>destination</key><string>export</string>",
    ]

    if manifest
      entries << <<~PLIST.chomp
        <key>manifest</key>
        <dict>
          <key>appURL</key><string>#{xml_escape(manifest[:app_url])}</string>
          <key>displayImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
          <key>fullSizeImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
        </dict>
      PLIST
    end

    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      #{entries.join("\n")}
      </dict>
      </plist>
    PLIST
    path
  end

  # Build the .ipa from source and return its path. It sits in a fresh tmp dir
  # the caller owns and must clean up; when `manifest:` is given, the OTA
  # `manifest.plist` is written **as a sibling** of the .ipa in that same dir,
  # so `File.dirname(ipa)` covers both and one remove_entry cleans up.
  #
  # `manifest:` is `{app_url:, icon_url:}` -- the public URLs the .ipa and its
  # icon will live at once published. Omit it for a build nobody installs OTA.
  #
  # `ota_manifest_url:` and `devlog_url:` go in as command-line build settings,
  # which Info.plist expands. An xcconfig file cannot carry them: it reads the
  # `//` in a URL as the start of a comment.
  def build(manifest: nil, ota_manifest_url: nil, devlog_url: nil)
    die("project not found: #{File.join(REPO_ROOT, PROJECT)}") unless Dir.exist?(File.join(REPO_ROOT, PROJECT))

    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{PRODUCT_NAME}.xcarchive")

    # Unsigned archives skip signing entirely; signed ones let Xcode fetch or
    # create the certificate and profile it needs (-allowProvisioningUpdates).
    signing = unsigned? ? "CODE_SIGNING_ALLOWED=NO " : "DEVELOPMENT_TEAM=#{team_id} "
    ota = ota_manifest_url ? "#{ENV_PREFIX}_OTA_MANIFEST_URL=#{Shellwords.escape(ota_manifest_url)} " : ""
    devlog = devlog_url ? "#{ENV_PREFIX}_DEVLOG_URL=#{Shellwords.escape(devlog_url)} " : ""

    step "Archiving (xcodebuild)#{unsigned? ? ' [UNSIGNED]' : ''}"
    run(
      "xcodebuild " \
      "-project #{Shellwords.escape(PROJECT)} " \
      "-scheme #{Shellwords.escape(SCHEME)} " \
      "-configuration Release " \
      "-destination 'generic/platform=iOS' " \
      "-archivePath #{Shellwords.escape(archive)} " \
      "#{signing}" \
      "#{ota}" \
      "#{devlog}" \
      "-allowProvisioningUpdates " \
      "-skipPackagePluginValidation " \
      "archive",
      chdir: REPO_ROOT
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)
    puts green("    Built: #{archive}")

    return package_unsigned(archive, work) if unsigned?

    step "Exporting signed .ipa (ad hoc)"
    options = export_options_plist(File.join(work, "ExportOptions.plist"), manifest: manifest)
    run(
      "xcodebuild -exportArchive " \
      "-archivePath #{Shellwords.escape(archive)} " \
      "-exportPath #{Shellwords.escape(work)} " \
      "-exportOptionsPlist #{Shellwords.escape(options)} " \
      "-allowProvisioningUpdates",
      chdir: REPO_ROOT
    )

    ipa = File.join(work, "#{PRODUCT_NAME}.ipa")
    unless File.exist?(ipa)
      die("export produced no .ipa in #{work} (see the xcodebuild output above). " \
          "If this is a signing failure, check that the Apple ID for team " \
          "#{team_id} is added in Xcode -> Settings -> Accounts, that the target " \
          "device is registered on the portal, and that the App ID " \
          "#{bundle_id || '(bundle ID)'} exists there: automatic signing creates " \
          "certificates and profiles, but not App IDs.")
    end
    ipa
  end

  # The pre-signing packaging path, kept for CLOUDCLI_UNSIGNED=1: zip the .app
  # into a Payload/ by hand so a resigning tool can sign it on-device.
  def package_unsigned(archive, work)
    app_path = File.join(archive, "Products", "Applications", "#{PRODUCT_NAME}.app")
    die("no #{PRODUCT_NAME}.app inside archive: #{app_path}") unless Dir.exist?(app_path)

    step "Packaging .ipa (unsigned)"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app_path, payload)

    ipa = File.join(work, "#{PRODUCT_NAME}.ipa")
    # ditto --keepParent keeps the Payload/ dir at the archive root and preserves
    # the symlinks inside embedded frameworks (plain zip can mangle them).
    run(
      "ditto -c -k --sequesterRsrc --keepParent " \
      "#{Shellwords.escape(payload)} #{Shellwords.escape(ipa)}",
      chdir: work
    )

    ipa
  end
end
