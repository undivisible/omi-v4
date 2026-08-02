import 'package:flutter/material.dart';

import '../app_services.dart';
import '../profile/user_profile_settings_panel.dart';
import 'setup_account_screens.dart';

// The paper palette the rest of the companion shell paints in, kept local so
// this screen stands alone without reaching into the shell's private colours.
const _paper = Color(0xfff7f6f1);
const _surface = Color(0xfffffefa);
const _ink = Color(0xff171716);
const _inkSoft = Color(0xff706e68);
const _hairline = Color(0x14171716);
const _inkSheet = Color(0xff1c1c1a);
const _cream = Color(0xfffffcec);

bool _dark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageInk(BuildContext context) => _dark(context) ? _cream : _ink;

Color _pageInkSoft(BuildContext context) =>
    _dark(context) ? const Color(0xffa6a49c) : _inkSoft;

Color _pageSurface(BuildContext context) =>
    _dark(context) ? const Color(0xff232320) : _surface;

Color _pageHairline(BuildContext context) =>
    _dark(context) ? const Color(0x1ffffcec) : _hairline;

Color _pageBackground(BuildContext context) =>
    _dark(context) ? _inkSheet : _paper;

/// The account- and product-level sections a phone can act on. Permissions,
/// Calendar and Rewind are left out on purpose: every row they hold is a
/// desktop capability (macOS Accessibility and Input Monitoring, screen
/// recording, system audio capture, EventKit) with nothing to grant on a
/// phone — and the one EventKit switch that does apply already has a home on
/// the companion sheet.
const mobileSettingsSections = [
  SettingsSection.account,
  SettingsSection.personal,
  SettingsSection.plan,
  SettingsSection.providers,
  SettingsSection.developer,
  SettingsSection.connections,
  SettingsSection.advanced,
];

/// One line under each section name, so the index reads as a set of choices
/// rather than a list of nouns.
String _blurb(SettingsSection section) => switch (section) {
  SettingsSection.account =>
    'Sign in, log out, link a chat, and delete your data.',
  SettingsSection.personal => 'What Omi assumes about you.',
  SettingsSection.plan => 'Your subscription and usage.',
  SettingsSection.providers => 'Bring your own AI subscription or API key.',
  SettingsSection.developer => 'API keys and the MCP endpoint.',
  SettingsSection.connections => 'Calendars, mail, and other read-only links.',
  SettingsSection.advanced => 'Approval policy and service health.',
  SettingsSection.permissions ||
  SettingsSection.calendar ||
  SettingsSection.rewind => '',
};

/// The phone's settings index. The desktop shows every section at once beside
/// a sidebar; a phone has room for one at a time, so each section is a row
/// that pushes its own page rather than a block on an already long sheet.
class MobileSettingsScreen extends StatelessWidget {
  const MobileSettingsScreen({
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final AppServices services;
  final bool previewMode;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('mobile_settings_screen'),
    backgroundColor: _pageBackground(context),
    appBar: _appBar(context, 'Settings'),
    body: ListView(
      key: const Key('mobile_settings_list'),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
      children: [
        for (final section in mobileSettingsSections) ...[
          _SectionRow(
            key: Key('mobile_settings_section_${section.name}'),
            section: section,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MobileSettingsSectionScreen(
                  section: section,
                  services: services,
                  previewMode: previewMode,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    ),
  );
}

/// One section, rendered from the very same tiles the desktop window builds.
class MobileSettingsSectionScreen extends StatefulWidget {
  const MobileSettingsSectionScreen({
    required this.section,
    required this.services,
    this.previewMode = false,
    super.key,
  });

  final SettingsSection section;
  final AppServices services;
  final bool previewMode;

  @override
  State<MobileSettingsSectionScreen> createState() =>
      _MobileSettingsSectionScreenState();
}

class _MobileSettingsSectionScreenState
    extends State<MobileSettingsSectionScreen> {
  /// The account rows are drawn from [AuthController.snapshot], and redeeming a
  /// sign-in code swaps almost every row on this page. Without this the page
  /// would keep showing the sign-in field after the session arrived.
  @override
  void initState() {
    super.initState();
    widget.services.auth.addListener(_authChanged);
  }

  @override
  void dispose() {
    widget.services.auth.removeListener(_authChanged);
    super.dispose();
  }

  void _authChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: Key('mobile_settings_${widget.section.name}_screen'),
    backgroundColor: _pageBackground(context),
    appBar: _appBar(context, widget.section.label),
    body: widget.section == SettingsSection.personal
        ? Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            child: UserProfileSettingsPanel(
              services: widget.services,
              previewMode: widget.previewMode,
            ),
          )
        : ListView(
            key: const Key('mobile_settings_section_list'),
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
            children: [
              SettingsTileGroup(
                children: settingsSectionTiles(
                  widget.section,
                  services: widget.services,
                  previewMode: widget.previewMode,
                ),
              ),
            ],
          ),
  );
}

PreferredSizeWidget _appBar(BuildContext context, String title) => AppBar(
  backgroundColor: _pageBackground(context),
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  foregroundColor: _pageInk(context),
  title: Text(
    title,
    style: TextStyle(
      color: _pageInk(context),
      fontSize: 17,
      fontWeight: FontWeight.w600,
    ),
  ),
);

class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.section, required this.onTap, super.key});

  final SettingsSection section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _pageSurface(context),
        border: Border.all(color: _pageHairline(context)),
        borderRadius: radius,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          // The entire row is the button; nothing on the right is separately
          // tappable, so the touch target always spans the full width.
          onTap: onTap,
          shape: RoundedRectangleBorder(borderRadius: radius),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: Icon(section.icon, color: _pageInkSoft(context)),
          title: Text(
            section.label,
            style: TextStyle(
              color: _pageInk(context),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _blurb(section),
              style: TextStyle(
                color: _pageInkSoft(context),
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: _pageInkSoft(context),
          ),
        ),
      ),
    );
  }
}
