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

/// Closes every page above the tabs: the tab's own, and any on the app's navigator.
void popToTabs(BuildContext context) {
  final tab = Navigator.of(context);
  final root = Navigator.of(context, rootNavigator: true);
  tab.popUntil((route) => route.isFirst);
  if (root != tab) root.popUntil((route) => route.isFirst);
}
