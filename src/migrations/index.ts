import * as migration_20261031_070239_initial from './20261031_070239_initial';

export const migrations = [
  {
    up: migration_20261031_070239_initial.up,
    down: migration_20261031_070239_initial.down,
    name: '20261031_070239_initial'
  },
];
