const Module = require('module');
const path = require('path');
const ts = require('typescript');

const sourcePath = path.join(__dirname, '..', 'src', 'TrackPlayerModule.ts');
const legacyModule = { marker: 'legacy-track-player-module' };
const originalLoad = Module._load;

Module._load = function patchedLoad(request, parent, isMain) {
  if (request === 'react-native') {
    return { NativeModules: { TrackPlayerModule: legacyModule } };
  }

  if (request === './NativeTrackPlayerModule') {
    return { __esModule: true, default: null };
  }

  return originalLoad.call(this, request, parent, isMain);
};

try {
  const output = ts.transpileModule(require('fs').readFileSync(sourcePath, 'utf8'), {
    compilerOptions: {
      esModuleInterop: true,
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2019,
    },
  }).outputText;

  const testModule = new Module(sourcePath, module.parent);
  testModule.filename = sourcePath;
  testModule.paths = Module._nodeModulePaths(path.dirname(sourcePath));
  testModule._compile(output, sourcePath);

  if (testModule.exports.default !== legacyModule) {
    throw new Error('TrackPlayerModule did not fall back to NativeModules.');
  }
} finally {
  Module._load = originalLoad;
}
