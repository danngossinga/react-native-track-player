import type { RemoteHandledEvent } from './RemoteHandledEvent';

export interface RemoteJumpBackwardEvent extends RemoteHandledEvent {
  /**
   * The number of seconds to jump backward.
   * See https://rntp.dev/docs/api/events#remotejumpbackward
   **/
  interval: number;
}
