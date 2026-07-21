import 'package:flutter/material.dart';

class GradientBackground extends StatelessWidget {
  const GradientBackground({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-.8, -.9),
          radius: 1.5,
          colors: [Color(0xff18332f), Color(0xff10181b), Color(0xff0b1013)],
          stops: [0, .46, 1],
        ),
      ),
      child: child,
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 5),
              Text(subtitle, style: const TextStyle(color: Colors.white60)),
            ],
          ),
        ),
        IconButton(onPressed: () {}, icon: const Icon(Icons.search_rounded)),
        IconButton(
          onPressed: () {},
          icon: const Icon(Icons.more_horiz_rounded),
        ),
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

class StatRow extends StatelessWidget {
  const StatRow({required this.values, super.key});

  final List<(String, String)> values;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            for (final value in values)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      value.$1,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    Text(
                      value.$2,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
          ],
        ),
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
