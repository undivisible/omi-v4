import 'package:flutter/material.dart';

export 'omi_orb.dart';

enum OmiButtonVariant { primary, secondary, destructive }

class OmiButton extends StatelessWidget {
  const OmiButton({
    required this.onPressed,
    required this.child,
    this.variant = OmiButtonVariant.primary,
    super.key,
  });

  static const _cream = Color(0xfffffcec);
  static const _ink = Color(0xff171716);
  static const _red = Color(0xffb42318);

  final VoidCallback? onPressed;
  final Widget child;
  final OmiButtonVariant variant;

  static const _textStyle = TextStyle(
    fontFamily: 'Avenir Next',
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  @override
  Widget build(BuildContext context) => switch (variant) {
    OmiButtonVariant.primary => FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        backgroundColor: _cream,
        foregroundColor: _ink,
        shape: const StadiumBorder(),
        textStyle: _textStyle,
      ),
      child: child,
    ),
    OmiButtonVariant.secondary => OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        foregroundColor: _cream,
        side: const BorderSide(color: Color(0x8cfffcec)),
        shape: const StadiumBorder(),
        textStyle: _textStyle,
      ),
      child: child,
    ),
    OmiButtonVariant.destructive => FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        backgroundColor: _red,
        foregroundColor: _cream,
        shape: const StadiumBorder(),
        textStyle: _textStyle,
      ),
      child: child,
    ),
  };
}

class GradientBackground extends StatelessWidget {
  const GradientBackground({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.18,
              colors: [Color(0xff11191c), Color(0xff090d10)],
            ),
          ),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-1.15, -1.05),
                radius: 1.05,
                colors: [Color(0x8073d5c4), Color(0x0010181b)],
                stops: [0, .74],
              ),
            ),
          ),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(1.25, -.8),
                radius: 1.1,
                colors: [Color(0x6696c4ff), Color(0x000b1013)],
                stops: [0, .72],
              ),
            ),
          ),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(.75, 1.25),
                radius: 1.12,
                colors: [Color(0x55f2a78f), Color(0x000b1013)],
                stops: [0, .72],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .055),
        border: Border.all(color: Colors.white.withValues(alpha: .09)),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

class OmiMark extends StatelessWidget {
  const OmiMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xff73d5c4), Color(0xffbce8a8)],
            ),
          ),
          child: const Icon(
            Icons.blur_on_rounded,
            color: Color(0xff10201e),
            size: 19,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'omi',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle({required this.title, required this.subtitle, super.key});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.displaySmall),
        ),
        const SizedBox(height: 5),
        Text(subtitle, style: const TextStyle(color: Colors.white60)),
      ],
    );
  }
}

class PageList extends StatelessWidget {
  const PageList({
    required this.title,
    required this.subtitle,
    required this.children,
    super.key,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageTitle(title: title, subtitle: subtitle),
        const SizedBox(height: 20),
        Expanded(
          child: ListView.separated(
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) => children[index],
          ),
        ),
      ],
    );
  }
}

class OmiLabel extends StatelessWidget {
  const OmiLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xff73d5c4),
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

class BaseTile extends StatelessWidget {
  const BaseTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.trailing,
    this.iconColor,
    super.key,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String detail;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: Icon(icon, color: iconColor ?? const Color(0xff73d5c4)),
        title: Text(title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            detail,
            style: const TextStyle(color: Colors.white54, height: 1.4),
          ),
        ),
        trailing: trailing,
      ),
    );
  }
}
