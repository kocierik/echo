import 'package:flutter/material.dart';

/// Opens a conversation; returns once the detail is closed.
typedef ConversationOpener = Future<void> Function(BuildContext context, String id);

/// Sends a question to the Ask tab (in a new chat).
typedef AskCallback = void Function(String question);

/// From a pushed screen: back to the tabs, then ask [question] in Ask.
void askFromAnywhere(BuildContext context, AskCallback ask, String question) {
  Navigator.of(context).popUntil((route) => route.isFirst);
  ask(question);
}
