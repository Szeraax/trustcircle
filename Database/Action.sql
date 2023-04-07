CREATE TABLE [dbo].[Action] (
    [Id]           BIGINT        IDENTITY (1, 1) NOT NULL PRIMARY KEY CLUSTERED ([Id] ASC),
    [EntryTime] DATETIME2 DEFAULT (SYSDATETIME()),
    [Game]         INT           NULL,
    [Player]       VARCHAR(50)   NULL,
    [TargetPlayer] VARCHAR(50)   NULL,
    [Type]         VARCHAR (250) NULL,
    CONSTRAINT [FK_Action_Game] FOREIGN KEY ([Game]) REFERENCES [dbo].[Game] ([Id]) ON DELETE SET NULL ON UPDATE CASCADE
    
);
