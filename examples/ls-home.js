const fs = require('fs');
const os = require('os');

const homeDir = os.homedir();
fs.readdir(homeDir, (err, files) => {
  if (err) throw err;
  console.log(files);
});
