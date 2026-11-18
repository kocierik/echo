import 'package:flutter/material.dart';

/// Opens a conversation; returns once the detail is closed.
typedef ConversationOpener = Future<void> Function(BuildContext context, String id);

/// Sends a question to the Ask tab (in a new chat).
typedef AskCallback = void Function(String question);

/// From a pushed screen: back to the tabs, then ask [question] in Ask.
void askFromAnywhere(BuildContext context, AskCallback ask, String question) {
  popToTabs(context);
  ask(question);
}

/// The shell's tab navigators, while it is on screen: lets a page anywhere close them all.
final class TabNavigators {
  static List<GlobalKey<NavigatorState>> keys = const [];
}

/// Closes every page above the tabs: each tab's own, and any on the app's navigator.
void popToTabs(BuildContext context) {
  final navigators = {
    Navigator.of(context),
    Navigator.of(context, rootNavigator: true),
    for (final key in TabNavigators.keys)
      if (key.currentState != null) key.currentState!,
  };
  for (final navigator in navigators) {
    navigator.popUntil((route) => route.isFirst);
  }
}
