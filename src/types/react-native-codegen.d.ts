declare module 'react-native/Libraries/Types/CodegenTypes' {
  import type { EmitterSubscription } from 'react-native';

  export type Double = number;
  export type Float = number;
  export type Int32 = number;
  export type UnsafeMixed = unknown;
  export type UnsafeObject = object;
  export type EventEmitter<T> = (
    handler: (event: T) => void | Promise<void>
  ) => EmitterSubscription;
}
