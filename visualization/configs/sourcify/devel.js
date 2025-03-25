const {
  RWStorageIdentifiers,
} = require("../server/services/storageServices/identifiers");

module.exports = {
  storage: {
    read: RWStorageIdentifiers.RepositoryV1,
    writeOrWarn: [],
    writeOrErr: [RWStorageIdentifiers.RepositoryV1],
  },
};
