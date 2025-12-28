import AbortController from 'abort-controller';
import { fromByteArray, toByteArray } from 'base64-js';
import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import { GrpcError } from './errors';
import
  {
    GrpcServerStreamingCall,
    ServerOutputStream,
  } from './server-streaming';
import { GrpcMetadata } from './types';
import { GrpcUnaryCall } from './unary';

type GrpcRequestObject = {
  data: string;
};
type AbortSignal = any;

// We cast to any to allow dynamic checking of methods for backward compatibility
const Grpc = NativeModules.Grpc as any;

const Emitter = new NativeEventEmitter(NativeModules.Grpc);

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason: any) => void;
};

type DeferredCalls = {
  headers?: Deferred<GrpcMetadata>;
  response?: Deferred<Uint8Array>;
  trailers?: Deferred<GrpcMetadata>;
  data?: ServerOutputStream;
};

type DeferredCallMap = {
  [id: number]: DeferredCalls;
};

function createDeferred<T>(signal: AbortSignal)
{
  let completed = false;

  const deferred: Deferred<T> = {} as any;

  deferred.promise = new Promise<T>((resolve, reject) =>
  {
    deferred.resolve = (value) =>
    {
      completed = true;

      resolve(value);
    };
    deferred.reject = (reason) =>
    {
      completed = true;

      reject(reason);
    };
  });

  signal.addEventListener('abort', () =>
  {
    if (!completed)
    {
      deferred.reject('aborted');
    }
  });

  return deferred;
}

let idCtr = 1;

const deferredMap: DeferredCallMap = {};

function handleGrpcEvent(event: any)
{
  const deferred = deferredMap[event.id];

  if (deferred)
  {
    switch (event.type)
    {
      case 'headers':
        deferred.headers?.resolve(event.payload);
        break;
      case 'response':
        const data = toByteArray(event.payload);

        deferred.data?.notifyData(data);
        deferred.response?.resolve(data);
        break;
      case 'trailers':
        deferred.trailers?.resolve(event.payload);
        deferred.data?.notifyComplete();

        delete deferredMap[event.id];
        break;
      case 'error':
        const error = new GrpcError(event.error, event.code, event.trailers);

        deferred.headers?.reject(error);
        deferred.trailers?.reject(error);
        deferred.response?.reject(error);
        deferred.data?.noitfyError(error);

        delete deferredMap[event.id];
        break;
    }
  }
}

function getId(): number
{
  return idCtr++;
}

export class GrpcClient
{
  private currentHost: string | null = null;
  private currentInsecure: boolean = false;
  private clientId = 1; // Default client ID for multi-client support

  constructor()
  {
    Emitter.addListener('grpc-call', handleGrpcEvent);
  }
  destroy()
  {
    Emitter.removeAllListeners('grpc-call');
  }

  // --- Hybrid API Implementation ---

  getHost(): Promise<string>
  {
    if (Grpc.getHost)
    {
      return Grpc.getHost();
    }
    // Fallback if getHost is missing (Android New API doesn't seem to have a getter easily exposed, or it's per-client)
    return Promise.resolve(this.currentHost || "");
  }

  setHost(host: string): void
  {
    this.currentHost = host;
    if (Grpc.setGrpcSettings)
    {
      // Android New API (Multi-client)
      Grpc.setGrpcSettings(this.clientId, { host: host, insecure: this.currentInsecure });
    } else if (Grpc.setHost)
    {
      // iOS / Old API
      Grpc.setHost(host);
    }
  }

  getInsecure(): Promise<boolean>
  {
    if (Grpc.getIsInsecure) return Grpc.getIsInsecure();
    return Promise.resolve(this.currentInsecure);
  }

  setInsecure(insecure: boolean): void
  {
    this.currentInsecure = insecure;
    if (Grpc.setGrpcSettings)
    {
      if (this.currentHost)
      {
        Grpc.setGrpcSettings(this.clientId, { host: this.currentHost, insecure: insecure });
      }
    } else if (Grpc.setInsecure)
    {
      Grpc.setInsecure(insecure);
    }
  }

  setCompression(enable: boolean, compressorName: string): void
  {
    if (Grpc.setCompression)
    {
      Grpc.setCompression(enable, compressorName);
    }
    // If new API supports compression via settings, it should be added to setGrpcSettings map.
    // Assuming for now simple setCompression might not be there or processed differently.
  }

  setResponseSizeLimit(limitInBytes: number): void
  {
    if (Grpc.setResponseSizeLimit)
    {
      Grpc.setResponseSizeLimit(limitInBytes);
    } else if (Grpc.setGrpcSettings && this.currentHost)
    {
      Grpc.setGrpcSettings(this.clientId, {
        host: this.currentHost,
        insecure: this.currentInsecure,
        responseSizeLimit: limitInBytes
      });
    }
  }

  initGrpcChannel()
  {
    if (Grpc.initGrpcChannel) Grpc.initGrpcChannel();
  }

  setKeepAlive(
    enable: boolean,
    keepAliveTime: number,
    keepAliveTimeOut: number
  ): void
  {
    if (Grpc.setKeepAlive)
    {
      Grpc.setKeepAlive(enable, keepAliveTime, keepAliveTimeOut);
    }
    // TODO: support via setGrpcSettings if needed
  }

  resetConnection(message: string): void
  {
    if (!this.isAndroid()) return;
    if (Grpc.resetConnection) Grpc.resetConnection(message);
  }
  setUiLogEnabled(enable: boolean): void
  {
    if (!this.isAndroid()) return;
    if (Grpc.setUiLogEnabled) Grpc.setUiLogEnabled(enable);
  }

  onConnectionStateChange(): void
  {
    if (!this.isAndroid()) return;
    if (Grpc.onConnectionStateChange) Grpc.onConnectionStateChange();
  }

  enterIdle(): void
  {
    if (!this.isAndroid()) return;
    if (Grpc.enterIdle) Grpc.enterIdle();
  }

  unaryCall(
    method: string,
    data: Uint8Array,
    requestHeaders?: GrpcMetadata
  ): GrpcUnaryCall
  {
    const requestData = fromByteArray(data);
    const obj: GrpcRequestObject = {
      data: requestData,
    };

    const id = getId();
    const abort = new AbortController();

    abort.signal.addEventListener('abort', () =>
    {
      if (Grpc.cancelGrpcCall) Grpc.cancelGrpcCall(id);
    });

    const response = createDeferred<Uint8Array>(abort.signal);
    const headers = createDeferred<GrpcMetadata>(abort.signal);
    const trailers = createDeferred<GrpcMetadata>(abort.signal);

    deferredMap[id] = {
      response,
      headers,
      trailers,
    };

    if (Grpc.setGrpcSettings)
    {
      // Android New API: unaryCall(callId, clientId, method, obj, headers, promise)
      // Note: Java expects 'Integer id' as 2nd arg which is clientId
      Grpc.unaryCall(id, this.clientId, method, obj, requestHeaders || {});
    } else
    {
      // iOS / Old API: unaryCall(callId, method, obj, headers, promise)
      Grpc.unaryCall(id, method, obj, requestHeaders || {});
    }

    const call = new GrpcUnaryCall(
      method,
      data,
      requestHeaders || {},
      headers.promise,
      response.promise,
      trailers.promise,
      abort
    );

    call.then(
      (result) => result,
      () => abort.abort()
    );

    return call;
  }
  serverStreamCall(
    method: string,
    data: Uint8Array,
    requestHeaders?: GrpcMetadata
  ): GrpcServerStreamingCall
  {
    const requestData = fromByteArray(data);
    const obj: GrpcRequestObject = {
      data: requestData,
    };

    const id = getId();
    const abort = new AbortController();

    abort.signal.addEventListener('abort', () =>
    {
      if (Grpc.cancelGrpcCall) Grpc.cancelGrpcCall(id);
    });

    const headers = createDeferred<GrpcMetadata>(abort.signal);
    const trailers = createDeferred<GrpcMetadata>(abort.signal);

    const stream = new ServerOutputStream();

    deferredMap[id] = {
      headers,
      trailers,
      data: stream,
    };

    if (Grpc.setGrpcSettings)
    {
      // Android New API
      Grpc.serverStreamingCall(id, this.clientId, method, obj, requestHeaders || {});
    } else
    {
      // iOS / Old API
      Grpc.serverStreamingCall(id, method, obj, requestHeaders || {});
    }

    const call = new GrpcServerStreamingCall(
      method,
      data,
      requestHeaders || {},
      headers.promise,
      stream,
      trailers.promise,
      abort
    );

    call.then(
      (result) => result,
      () => abort.abort()
    );

    return call;
  }

  private isAndroid(): Boolean
  {
    return Platform.OS === 'android';
  }
}

export { Grpc };
