import { webSocket } from '@kit.NetworkKit';
import { AppState } from '../common/AppState';

type OpenCb = () => void;
type MsgCb = (jsonText: string) => void;
type ErrCb = (msg: string) => void;

/** 带自动重连的 WebSocket 客户端（服务器只做问题检测）。 */
export class WsClient {
  private ws: webSocket.WebSocket | null = null;
  private url: string = '';
  private running: boolean = false;
  private retry: number = 0;
  private connected: boolean = false;

  onOpen: OpenCb = () => {};
  onMessage: MsgCb = () => {};
  onError: ErrCb = () => {};

  isConnected(): boolean {
    return this.connected;
  }

  start(url: string): void {
    this.url = url;
    this.running = true;
    this.retry = 0;
    this.closeSocket();   // 先扔掉上一轮连接，避免旧连接事件干扰
    this.connect();
  }

  stop(): void {
    this.running = false;
    this.connected = false;
    this.closeSocket();
  }

  send(jsonText: string): boolean {
    const ws = this.ws;
    if (!this.connected || ws == null) {
      return false;
    }
    try {
      ws.send(jsonText);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 关闭并丢弃当前 socket；其后续 close/error 事件由回调内的身份校验忽略。 */
  private closeSocket(): void {
    const ws = this.ws;
    this.ws = null;
    if (ws != null) {
      try {
        ws.close();
      } catch (e) {
        // ignore
      }
    }
  }

  private connect(): void {
    if (!this.running) {
      return;
    }
    if (this.url.trim().length === 0) {
      this.running = false;
      this.onError('未配置检测服务器，已使用端侧检测（可在设置里填写）');
      return;
    }
    this.closeSocket();
    // 每次连接都新建 socket：复用同一实例反复 connect 会叠加监听器，
    // 同一条消息被处理多次（问题列表出现重复项）
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    ws.on('open', () => {
      this.connected = true;
      this.retry = 0;
      this.onOpen();
    });
    ws.on('message', (_err: Error, value: string | ArrayBuffer) => {
      if (this.ws !== ws) {
        return;   // 已被替换 / 已停止的旧连接：丢弃
      }
      if (typeof value === 'string') {
        this.onMessage(value);
      }
    });
    ws.on('close', (_err: Error, value: webSocket.CloseResult) => {
      if (this.ws !== ws) {
        return;   // 旧连接关闭事件：不报错也不重连
      }
      this.connected = false;
      this.onError(`连接关闭(${value.code}): ${value.reason}`);
      this.scheduleReconnect();
    });
    ws.on('error', (err: Error) => {
      if (this.ws !== ws) {
        return;
      }
      this.connected = false;
      this.onError(err.message ?? '网络错误');
      this.scheduleReconnect();
    });
    ws.connect(this.url)
      .then(() => {
        // connect 成功时 open 事件会触发
      })
      .catch(() => {
        if (this.ws !== ws) {
          return;
        }
        this.connected = false;
        this.scheduleReconnect();
      });
  }

  private scheduleReconnect(): void {
    if (!this.running) {
      return;
    }
    const delay = 1000 * Math.pow(2, Math.min(this.retry, 5));
    this.retry += 1;
    setTimeout(() => {
      this.connect();
    }, delay);
  }
}

/** 服务器下行消息的轻量解析（question / error 等）。 */
export class ServerMsg {
  type: string = '';
  isQuestion: boolean = false;
  question: string = '';
  confidence: number = 0;
  message: string = '';

  static parse(raw: string): ServerMsg | null {
    try {
      const o: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const m = new ServerMsg();
      m.type = WsClientHelper.str(o, 'type');
      if (m.type === 'question') {
        m.isQuestion = WsClientHelper.bool(o, 'is_question') || WsClientHelper.bool(o, 'isQuestion');
        m.question = WsClientHelper.str(o, 'question');
        m.confidence = WsClientHelper.num(o, 'confidence');
      } else if (m.type === 'error') {
        m.message = WsClientHelper.str(o, 'message');
      }
      return m;
    } catch (e) {
      return null;
    }
  }
}

class WsClientHelper {
  static str(o: Record<string, Object>, k: string): string {
    const v = o[k];
    return typeof v === 'string' ? v as string : '';
  }

  static bool(o: Record<string, Object>, k: string): boolean {
    const v = o[k];
    return typeof v === 'boolean' ? v as boolean : false;
  }

  static num(o: Record<string, Object>, k: string): number {
    const v = o[k];
    return typeof v === 'number' ? v as number : 0;
  }
}

export { AppState };