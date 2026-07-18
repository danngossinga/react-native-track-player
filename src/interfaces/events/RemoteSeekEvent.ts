import type { RemoteHandledEvent } from './RemoteHandledEvent';

export interface RemoteSeekEvent extends RemoteHandledEvent {
  /** The position to seek to in seconds. */
  position: number;
}
