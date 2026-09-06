import 'package:flutter/material.dart';

/// The shape every screen shares: a heading, a list, and one way to add.
///
/// The empty state carries the explanation rather than a separate help screen,
/// since the moment a user needs to know what an account is for is the moment
/// they have none.
class EntityList extends StatelessWidget {
  final String title;
  final String blurb;
  final String addLabel;
  final VoidCallback? onAdd;
  final List<Widget> children;

  /// Shown in place of the list when it is empty.
  final String emptyMessage;

  /// The flags this screen owns, shown between the heading and the list so
  /// they are read before the thing they are about.
  final Widget? banner;

  const EntityList({
    super.key,
    required this.title,
    required this.blurb,
    required this.addLabel,
    required this.emptyMessage,
    required this.children,
    this.onAdd,
    this.banner,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                blurb,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        ?banner,
        Expanded(
          child: children.isEmpty && emptyMessage.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      emptyMessage,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 96),
                  children: [
                    for (final child in children)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: child,
                      ),
                  ],
                ),
        ),
        if (onAdd != null && addLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(addLabel),
              ),
            ),
          ),
      ],
    );
  }
}

/// A heading and its own add button, for a screen holding more than one kind
/// of thing.
///
/// The add button sits with the section rather than at the foot of the page:
/// one button under a list of employers reads as "add an employer", and the
/// same button after three lists reads as nothing in particular.
class EntitySection extends StatelessWidget {
  final String title;
  final String? blurb;
  final String addLabel;
  final VoidCallback? onAdd;
  final List<Widget> children;

  /// Shown in place of the list when this section is empty.
  final String? emptyMessage;

  const EntitySection({
    super.key,
    required this.title,
    required this.addLabel,
    required this.children,
    this.onAdd,
    this.blurb,
    this.emptyMessage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(title, style: theme.textTheme.titleSmall),
        if (blurb != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              blurb!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 8),
        if (children.isEmpty && emptyMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              emptyMessage!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        for (final child in children)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: child,
          ),
        if (onAdd != null)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: Text(addLabel),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// One row in an entity list: what it is, what it is worth, and a way in.
class EntityTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const EntityTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailing != null)
              Text(trailing!,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove',
                onPressed: onDelete,
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

/// Editors open in a dialog on a wide window and a full sheet on a narrow one,
/// because a form squeezed into a phone-width dialog is unusable and a
/// full-screen takeover on a desktop loses the results panel the user is
/// watching.
Future<T?> showEditor<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext) build,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 600;
  if (wide) {
    return showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: _EditorFrame(title: title, child: build(context)),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _EditorFrame(title: title, child: build(context)),
    ),
  );
}

class _EditorFrame extends StatelessWidget {
  final String title;
  final Widget child;

  const _EditorFrame({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          AppBar(
            title: Text(title),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ],
      );
}
