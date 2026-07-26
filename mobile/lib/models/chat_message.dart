class ChatMessage {
  final String text;
  final bool isUser;
  final int? index;
  String? feedback;

  ChatMessage({required this.text, required this.isUser, this.index, this.feedback});
}
