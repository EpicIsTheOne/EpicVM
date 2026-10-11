// Exercise the real pinned Moonlight modules with browser gamepad index gaps.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const root = path.resolve(process.argv[2]);
let pads = [];
const context = vm.createContext({
  console, EventTarget, performance,
  navigator: { getGamepads: () => pads },
  window: { setInterval: () => 1, clearInterval() {} },
});
const cache = new Map();
async function moduleAt(file) {
  if (cache.has(file)) return cache.get(file);
  const source = file.endsWith('notification.js')
    ? 'export function showNotification() {}'
    : fs.readFileSync(file, 'utf8');
  const module = new vm.SourceTextModule(source, { context, identifier: file });
  cache.set(file, module);
  await module.link((specifier, referencing) => moduleAt(path.resolve(path.dirname(referencing.identifier), specifier)));
  return module;
}
const module = await moduleAt(path.join(root, 'stream/input.js'));
await module.evaluate();
const input = new module.namespace.StreamInput();
const arrivals = [], removals = [], states = [];
const capabilities = [], effects = [];
input.connected = true;
input.controllers = {};
input.sendControllerAdd = (id, buttons, flags) => { arrivals.push(id); capabilities.push(flags); };
input.sendControllerRemove = id => removals.push(id);
input.sendController = (id, state) => states.push({ id, ...state });
function pad(index, button) {
  const buttons = Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }));
  buttons[button] = { pressed: true, value: 1 };
  buttons[6].value = 0.75;
  buttons[7].value = 0.25;
  return { index, mapping: 'standard', buttons, axes: [0.5, -0.25, -0.75, 1],
    vibrationActuator: { effects: ['dual-rumble', 'trigger-rumble'],
      playEffect: (type, params) => effects.push({ index, type, ...params }) } };
}
pads[3] = pad(3, 0);
pads[7] = pad(7, 1);
input.onGamepadConnect(pads[3]);
input.onGamepadConnect(pads[7]);
assert.deepEqual(arrivals, [0, 1], 'browser indices must map to compact protocol slots');
assert.equal(capabilities[0], 6, 'both rumble capabilities must be advertised');
input.onControllerData(Uint8Array.from([0, 1, 255, 255, 0, 0]).buffer);
input.onGamepadRumbleInterval();
assert.ok(effects.some(e => e.index === 7 && e.type === 'dual-rumble' && e.weakMagnitude === 1),
  'rumble must reach the browser controller mapped to protocol slot 1');
assert.ok(effects.filter(e => e.index === 3).every(e => !e.weakMagnitude && !e.strongMagnitude),
  'another controller must stay neutral');
input.onGamepadDisconnect({ gamepad: pads[3] });
pads[3] = null;
assert.deepEqual(removals, [0], 'disconnect must remove its protocol slot');
input.onGamepadUpdate();
assert.equal(states.length, 1, 'a hole must not stop the remaining controller');
assert.equal(states[0].id, 1);
assert.equal(states[0].buttonFlags, 4096);
assert.equal(states[0].leftTrigger, 0.75);
assert.equal(states[0].rightStickX, -0.75);
pads[9] = pad(9, 2);
input.onGamepadConnect(pads[9]);
assert.deepEqual(arrivals, [0, 1, 0], 'replug must reuse the vacant protocol slot');
input.onGamepadDisconnect({ gamepad: pads[7] });
assert.deepEqual(removals, [0, 1]);
input.resetControllers();
assert.deepEqual(removals, [0, 1, 0], 'reset must release all remaining slots');
console.log('Gamepad slot, unplug/replug, surviving-pad and analog-state checks passed');
