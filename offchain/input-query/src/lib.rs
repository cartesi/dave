//! A library that provides the [Query] struct to query the input from the rollups contracts and 
//! store it in a SQLite database.

use std::str::FromStr;

use cartesi_rollups_contracts::input_box::InputAddedFilter;
use rollups_input_reader::InputReader;
use ethers::types::H160;

pub struct Query {
    provider: InputReader,
    connection: sqlite::Connection
}

impl Query {
    pub fn connect(database_uri: String, provider: InputReader) -> Result<Self, Box<dyn std::error::Error>> {
        let connection = sqlite::Connection::open(database_uri)?;
        Ok(Self {
            provider,
            connection
        })
    }

    pub fn configure(&self) -> Result<(), Box<dyn std::error::Error>> {
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS input (
                app TEXT NOT NULL,
                index TEXT NOT NULL,
                input BLOB NOT NULL
            )"
        )?;
        Ok(())
    }

    fn insert(&self, app: String, index: String, input: Vec<u8>) -> Result<(), Box<dyn std::error::Error>> {
        let mut sttm = self.connection.prepare("INSERT INTO input (app, index, input) VALUES (?, ?, ?)")?;

        sttm.bind((1, app.as_str()))?;
        sttm.bind((2, index.as_str()))?;
        sttm.bind((3, input.as_slice()))?;

        Ok(())
    }

    pub fn get(&self, app: String, index: String) -> Result<InputAddedFilter, Box<dyn std::error::Error>> {
        let mut sttm = self.connection.prepare("SELECT input FROM input WHERE app = ? AND index = ?")?;

        sttm.bind((1, app.as_str()))?;
        sttm.bind((2, index.as_str()))?;

        sttm.next()?;

        let app = sttm.read::<String, _>(0)?;
        let index = sttm.read::<String, _>(1)?;
        let input = sttm.read::<Vec<u8>, _>(2)?;

        Ok(InputAddedFilter {
            app: H160::from_str(app.as_str()).unwrap(),
            index: index.parse().unwrap(),
            input: ethers::types::Bytes::from(input)
        })
    }

    pub async fn query(&mut self) -> Result<Vec<InputAddedFilter>, Box<dyn std::error::Error>> {
        let logs = self.provider.next().await?;

        for log in &logs {
            self.insert(log.app.to_string(), log.index.to_string(), log.input.to_vec())?;
        }

        Ok(logs)
    }
}