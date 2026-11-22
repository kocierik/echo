import '../../models/segment.dart';
import '../../models/voice.dart';
import '../../utils/formatting.dart';
import 'api_client.dart';

/// Known voices: the user's own (recorded for it) and people named in transcripts.
abstract interface class VoiceApi {
  Future<VoiceProfiles> getVoiceProfiles();

  /// The segments recorded between the two times are the user's voice.
  Future<VoiceEnrollment> enrollOwnVoice(DateTime startedAt, DateTime endedAt);

  Future<void> deleteVoiceProfile(String id);

  /// Whose voice a segment is: the user's, a person of theirs, or a new name. Returns
  /// how many other segments of the conversation were labelled with it.
  ///
  /// With [turn], whose voice that one turn of the segment is (several spoke in it).
  Future<int> nameVoice(
    String segmentId, {
    bool isSelf,
    String? personId,
    String? name,
    int? turn,
  });

  /// Not the suggested person.
  Future<void> rejectVoice(String segmentId);

  /// What Echo transcribed of the speech recorded since [since], oldest first: shown
  /// while the user records their voice, so they see Echo hears them.
  Future<List<String>> heardSince(DateTime since);
}

mixin VoiceEndpoints on ApiClient implements VoiceApi {
  @override
  Future<List<String>> heardSince(DateTime since) async {
    final response = await get('/api/segments/recent?limit=20', shape: JsonShape.list);
    final segments = parse(
      response.data,
      (data) => [
        for (final item in data as List<dynamic>)
          RecentSegment.fromJson(item as Map<String, dynamic>),
      ],
    );
    final heard = segments.where((s) => !s.recordedAt.isBefore(since)).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    return [
      for (final segment in heard)
        if (cleanTranscript(segment.text ?? '') case final text when text.isNotEmpty) text,
    ];
  }

  @override
  Future<VoiceProfiles> getVoiceProfiles() async {
    final response = await getCached('/api/voice-profiles');
    return parse(
      response.data,
      (data) => VoiceProfiles.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<VoiceEnrollment> enrollOwnVoice(DateTime startedAt, DateTime endedAt) async {
    final response = await post('/api/voice-profiles/self/enroll', body: {
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt.toUtc().toIso8601String(),
    });
    return parse(
      response.data,
      (data) => VoiceEnrollment.fromJson(data as Map<String, dynamic>),
    );
  }

  @override
  Future<void> deleteVoiceProfile(String id) =>
      delete('/api/voice-profiles/$id');

  @override
  Future<int> nameVoice(
    String segmentId, {
    bool isSelf = false,
    String? personId,
    String? name,
    int? turn,
  }) async {
    final response = await post('/api/segments/$segmentId/voice', body: {
      'is_self': isSelf,
      if (personId != null) 'person_id': personId,
      if (name != null) 'name': name,
      if (turn != null) 'turn': turn,
    });
    return parse(
      response.data,
      (data) => (data as Map<String, dynamic>)['relabelled'] as int,
    );
  }

  @override
  Future<void> rejectVoice(String segmentId) async {
    await post(
      '/api/segments/$segmentId/voice/reject',
      expect: const {204},
      decode: false,
    );
  }
}
