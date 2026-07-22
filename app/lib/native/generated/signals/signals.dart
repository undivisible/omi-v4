// ignore_for_file: type=lint
// ignore_for_file: unused_import
library signals_types;

import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:tuple/tuple.dart';
import '../serde/serde.dart';
import '../bincode/bincode.dart';

import 'dart:async';
import 'package:rinf/rinf.dart';

export '../serde/serde.dart';

part 'trait_helpers.dart';
part 'action_proposal.dart';
part 'action_risk.dart';
part 'approval_decision.dart';
part 'approval_decision_acknowledgement.dart';
part 'assistant_delta.dart';
part 'assistant_provider.dart';
part 'audio_chunk.dart';
part 'audio_encoding.dart';
part 'capture_source.dart';
part 'client_command.dart';
part 'command.dart';
part 'computer_use_action.dart';
part 'computer_use_action_capability.dart';
part 'computer_use_authority_receipt.dart';
part 'computer_use_background_support.dart';
part 'computer_use_capabilities.dart';
part 'computer_use_delivery_route.dart';
part 'computer_use_permission.dart';
part 'computer_use_session_isolation.dart';
part 'computer_use_target_provenance.dart';
part 'current_update.dart';
part 'live_voice_audio.dart';
part 'live_voice_phase.dart';
part 'live_voice_state.dart';
part 'live_voice_transcript.dart';
part 'memory_captured.dart';
part 'memory_corrected.dart';
part 'memory_export_commit.dart';
part 'memory_exported.dart';
part 'memory_item.dart';
part 'memory_items.dart';
part 'memory_search_item.dart';
part 'memory_search_results.dart';
part 'memory_source_deleted.dart';
part 'native_error.dart';
part 'native_event.dart';
part 'onboarding_scan_completed.dart';
part 'onboarding_scan_source.dart';
part 'onboarding_scan_state.dart';
part 'runtime_phase.dart';
part 'runtime_status.dart';
part 'tool_progress.dart';
part 'tool_status.dart';
part 'transcript_delta.dart';
part 'transcript_gap.dart';
part 'transcript_locator.dart';
part 'transcription_auth.dart';
part 'transcription_route.dart';
part 'transcription_state.dart';
part 'transcription_status.dart';
part 'transcription_stop_acknowledgement.dart';
part 'signal_handlers.dart';
