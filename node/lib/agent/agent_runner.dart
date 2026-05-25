/// Agent 执行状态枚举
enum AgentRunState { starting, running, completed, aborted, error }

/// Agent 事件的内部表示
///
/// 由各 Runner 实现将 Agent CLI 的输出翻译为此统一格式，
/// 再由 NodeDaemon 包装为 MobilePiMessage(event) 发送给 Client。
/// Structured thinking boundary (not mixed into streaming text).
enum ThinkingBoundary { start, end }

class AgentEvent {
  final AgentRunState state;
  final String? streamingText;
  final String? toolName;
  final String? toolCallId;
  final String? toolResult;
  final bool? toolResultIsError;
  final double? progress;
  final int? linesAdded;
  final int? linesRemoved;

  /// Non-null when a thinking boundary is crossed.
  /// `start` = model begins thinking; `end` = thinking done.
  /// Text deltas during thinking still go through [streamingText].
  final ThinkingBoundary? thinkingBoundary;

  /// Non-null when the agent emits a status label (compaction, retry, etc.)
  /// that should be shown to the user but is *not* part of the markdown text.
  final String? statusLabel;

  const AgentEvent({
    this.state = AgentRunState.running,
    this.streamingText,
    this.toolName,
    this.toolCallId,
    this.toolResult,
    this.toolResultIsError,
    this.progress,
    this.linesAdded,
    this.linesRemoved,
    this.thinkingBoundary,
    this.statusLabel,
  });
}

/// Agent Runner 抽象接口
///
/// Pi runner 实现此接口，
/// 封装子进程启动、消息收发、事件翻译。
abstract class AgentRunner {
  /// Agent 类型标识（当前固定为 "pi"）
  String get agentType;

  /// 是否正在运行
  bool get isRunning;

  /// 启动 Agent 子进程执行指定 prompt
  Future<void> start(String taskId, String prompt, {String? model});

  /// 在已启动并空闲的 Agent 会话中启动一个新 turn
  Future<void> prompt(String message);

  /// 中途调校 — 在 Agent 运行时发送纠正指令
  Future<void> steer(String message);

  /// 后续指令 — 在 Agent 运行时排队到当前 turn 结束后执行
  Future<void> followUp(String message);

  /// 恢复已有会话并准备继续交互
  Future<void> resumeSession(
    String taskId,
    String sessionPath, {
    String? model,
  });

  /// 强行终止 Agent 子进程
  Future<void> abort();

  /// 事件流，由 NodeDaemon 订阅并翻译为 protocol event
  Stream<AgentEvent> get eventStream;
}
