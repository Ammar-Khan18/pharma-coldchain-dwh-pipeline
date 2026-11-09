from datetime import datetime
from airflow.sdk import dag, task

@dag(start_date=datetime(2026, 11, 1), schedule=None, catchup=False)
def hello_ida():
    @task
    def say_hi():
        print("Pipeline environment works!")
    say_hi()

hello_ida()
