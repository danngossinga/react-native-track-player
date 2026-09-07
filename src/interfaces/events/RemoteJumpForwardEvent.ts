import type { RemoteHandledEvent } from './RemoteHandledEvent';

export interface RemoteJumpForwardEvent extends RemoteHandledEvent {
  /**
   * The number of seconds to jump forward.
   * See https://rntp.dev/docs/api/events#remotejumpforward
   **/
  interval: number;
}
