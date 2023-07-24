import boto3
import logging
from datetime import datetime, timedelta
from pyspark.context import SparkContext
from pyspark.sql import SparkSession, GlueContext
from pyspark.sql.window import Window
from pyspark.sql import functions as F
import json
import pandas as pd
import calendar

# Configure Python logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
stream_handler = logging.StreamHandler()
stream_handler.setFormatter(formatter)
logger.addHandler(stream_handler)

s3_base_path = 's3a://banking_data'
landing = 'bronze'
transform = 'silver'
year_month = datetime.now().strftime('%Y%m')

def get_secrets(secret_name):
    try:
        secrets_manager_client = boto3.client('secretsmanager', region_name='region')
        response = secrets_manager_client.get_secret_value(SecretId=secret_name)
        secret_data = response.get('SecretString')
        if not secret_data:
            raise ValueError('Failed to retrieve secrets from AWS Secrets Manager.')
        return json.loads(secret_data)
    except Exception as e:
        logger.error('Error while retrieving secrets from AWS Secrets Manager.')
        logger.exception(e)
        raise

def create_spark_session():
    try:
        sc = SparkContext()
        spark = SparkSession(sc).builder.appName('Data Extraction').getOrCreate()
        return spark
    except Exception as e:
        logger.error('Failed to create SparkSession.')
        logger.exception(e)
        raise

def extract_monthly_data(spark, aurora_properties, table_name, start_date, end_date):
    try:

        sql_query = f'''
            SELECT *
            FROM {table_name}
            WHERE date_column >= '{start_date}' AND date_column < '{end_date}'
        '''

        logger.info('Starting data extraction process for table: %s', table_name)

        with spark.read \
            .format('jdbc') \
            .option('driver', aurora_properties['driver']) \
            .option('url', aurora_properties['url']) \
            .option('dbtable', f'({sql_query}) as subquery') \
            .option('user', aurora_properties['user']) \
            .option('password', aurora_properties['password']) \
            .load() as df:

            logger.info('Data loaded successfully from Aurora.')

            
            s3_output_path = f'{s3_base_path}/{landing}/{table_name}/{year_month}/{table_name}_monthly_data_extract.csv'
            df.write.mode('overwrite').csv(s3_output_path)

            logger.info('Data saved successfully to S3.')

    except Exception as e:
        logger.error('An error occurred during data extraction for table: %s', table_name)
        logger.exception(e)
        raise

    finally:
        logger.info('Data extraction process completed for table: %s', table_name)

def transform_monthly_data(spark, table_name):
    try:
             
         # Load the tables from S3 into DataFrames

        df1 = spark.read.option('header', 'true').csv(f'{s3_base_path}/{landing}/{table_name}/*.csv')
        df2 = spark.read.option('header', 'true').csv(f'{s3_base_path}/{landing}/{table_name}/*.csv')
        df3 = spark.read.option('header', 'true').csv(f'{s3_base_path}/{landing}/{table_name}/*.csv')
        df4 = spark.read.option('header', 'true').csv(f'{s3_base_path}/{landing}/{table_name}/*.csv')
        df5 = spark.read.option('header', 'true').csv(f'{s3_base_path}/{landing}/{table_name}/*.csv')

        # Perform the join operation

        joined_df = df1.join(df2, df1['idBank'] == df2['Bank_idBank']) \
                    .join(df3, df1['idBranch'] == df3['Branch_idBranch']) \
                    .join(df4, df1['idClient'] == df4['Client_idClient']) \
                    .join(df5, df1['idAccount'] == df5['Account_idAccount'])
        
        
        joined_df = joined_df.orderBy('date')

        # Convert the date column to DateType
        joined_df = joined_df.withColumn('loan_date', F.to_date('year_month', 'yyyy-MM'))


        # Calculate the moving average of loan amounts taken out over the last three months by branch
        window_spec = Window.partitionBy('branch').orderBy(F.col('loan_date')).rowsBetween(-2, 0)
        joined_df = joined_df.withColumn('avgLoanAmount', F.avg('Amount').over(window_spec))

        #final_df = final_df.select(Name,'idBranch','avgLoanAmount')

        current_date = datetime.now().strftime('%Y%m%d')
        # Group by bank name dimension and save CSV files for each bank
        bank_names = final_df.select('Name').distinct().rdd.flatMap(lambda x: x).collect()
        for bank_name in bank_names:
            final_df = final_df.filter(final_df.bank_name == bank_name)
            final_df = final_df.select('idBranch','avgLoanAmount')
            s3_output_path = f'{s3_base_path}/{transform}/{bank_name}/{year_month}/{bank_name}_{current_date}.csv'
            final_df.write.mode('overwrite').csv(s3_output_path, header=True)




    except Exception as e:
        logger.error('An unexpected error occurred.')
        logger.exception(e)


def main():
    try:
        glueContext = GlueContext(SparkContext.getOrCreate())
        args = glueContext._jvm.sys.argv
        if len(args) < 2:
            raise ValueError('No table names provided as job parameters.')
        
        # Extract the list of table names passed as job parameters
        table_names = args[1:]

        spark = create_spark_session()

        # Get credentials from AWS Secrets Manager for Aurora
        aurora_credentials = get_secrets('your-aurora-secret-name')

        # Get Aurora endpoint (hostname) from the secrets
        aurora_endpoint = aurora_credentials.get('endpoint')
        if not aurora_endpoint:
            raise ValueError('Aurora endpoint not found in Secrets Manager response.')

        # Set the Aurora connection properties
        aurora_properties = {
            'user': aurora_credentials.get('username'),
            'password': aurora_credentials.get('password'),
            'driver': 'com.mysql.jdbc.Driver',
            'url': f'jdbc:mysql://{aurora_endpoint}:3306/BankingDB'
        }

        current_date = datetime.now()

        # Get the first and last day of the current month
        _, last_day = calendar.monthrange(current_date.year, current_date.month)
        start_date = current_date.replace(day=1).date()
        end_date = current_date.replace(day=last_day).date()

    
        # Stage the data
        for table_name in table_names:
            extract_monthly_data(spark, aurora_properties, table_name, start_date, end_date)

        #Load Transformed Data
        transform_monthly_data()

        spark.stop()

    except Exception as e:
        logger.error('An unexpected error occurred.')
        logger.exception(e)

if __name__ == '__main__':
    main()

