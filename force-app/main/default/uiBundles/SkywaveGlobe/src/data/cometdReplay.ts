/**
 * Minimal Salesforce CometD replay extension.
 *
 * Salesforce's Streaming API uses a per-channel `ext.replay` map to request
 * events from a replay point (-1 = only new, -2 = from the last 24h). The
 * stock `cometd` client doesn't ship this, so we register a small extension
 * that stamps the replay map on outgoing /meta/subscribe and tracks the
 * latest replayId seen per channel for reconnects.
 *
 * Adapted from Salesforce's published cometd-replay-extension (Apache-2.0).
 */
import type { Extension, Message } from 'cometd';

const REPLAY_FROM_KEY = 'replay';

export class ReplayExtension implements Extension {
  private extensionEnabled = true;
  private replayFromMap: Record<string, number> = {};

  /** Seed replay points before subscribing, e.g. { '/event/Foo__e': -1 }. */
  setReplay(replayMap: Record<string, number>): void {
    this.replayFromMap = { ...replayMap };
  }

  setExtensionEnabled(enabled: boolean): void {
    this.extensionEnabled = enabled;
  }

  outgoing(message: Message): Message {
    if (message.channel === '/meta/subscribe' && this.extensionEnabled) {
      const ext = (message.ext ?? {}) as Record<string, unknown>;
      ext[REPLAY_FROM_KEY] = this.replayFromMap;
      message.ext = ext;
    }
    return message;
  }

  incoming(message: Message): Message {
    if (message.channel && message.channel.startsWith('/event/') && message.data) {
      const data = message.data as { event?: { replayId?: number } };
      const replayId = data?.event?.replayId;
      if (typeof replayId === 'number') {
        this.replayFromMap[message.channel] = replayId;
      }
    }
    return message;
  }
}
